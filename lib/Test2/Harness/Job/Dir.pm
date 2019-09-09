package Test2::Harness::Job::Dir;
use strict;
use warnings;

our $VERSION = '0.001098';

use File::Spec();

use Carp qw/croak/;
use Time::HiRes qw/time/;
use List::Util qw/first/;

use Test2::Util qw/ipc_separator/;

use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Harness::Util qw/maybe_read_file open_file/;

use Test2::Harness::Event;

use Test2::Harness::Util::File::Stream;
use Test2::Harness::Util::File::JSONL;
use Test2::Harness::Util::File::Value;

use Test2::Harness::Util::TapParser qw{
    parse_stdout_tap
    parse_stderr_tap
};

use Test2::Harness::Util::HashBase qw{
    -run_id -job_id -job_root

    -_ready_buffer

    -_events_files -_events_buffer -_events_indexes -events_dir -_events_seen

    -stderr_file -_stderr_buffer -_stderr_index -_stderr_cg
    -stdout_file -_stdout_buffer -_stdout_index -_stdout_cg

    -start_file  -start_exists   -_start_buffer
    -exit_file   -_exit_done     -_exit_buffer

    -_file -file_file

    -last_stamp

    runner_exited
};

sub init {
    my $self = shift;

    croak "'run_id' is a required attribute"
        unless $self->{+RUN_ID};

    croak "'job_id' is a required attribute"
        unless $self->{+JOB_ID};

    croak "'job_root' is a required attribute"
        unless $self->{+JOB_ROOT};

    $self->{+_EVENTS_SEEN} = {};

    $self->{+_STDOUT_BUFFER} ||= [];
    $self->{+_STDERR_BUFFER} ||= [];
    $self->{+_EVENTS_BUFFER} ||= {};
    $self->{+_READY_BUFFER}  ||= [];

    $self->{+LAST_STAMP} = time();
}

sub poll {
    my $self = shift;
    my ($max) = @_;

    $self->_fill_buffers($max);

    my (@out, @new);

    # If we have a max number of events then we need to pass that along to the
    # inner-pollers, but we need to pass around how many MORE we need, this sub
    # will return the amount we still need.
    # If this finds that we do not need any more it will exit the loop instead
    # of returning a number.
    my $check = defined($max)
        ? sub {
        my $want = $max - scalar(@out) - scalar(@new);
        return undef if $want < 1;
        return $want;
        }
        : sub { 0 };

    while (!defined($max) || @out < $max) {
        # Micro-optimization, 'start' only ever has 1 thing, so do not enter
        # the sub if we do not need to.
        push @new => $self->_poll_start($check->() // last) if $self->{+_START_BUFFER};

        push @new => $self->_poll_streams($check->() // last);

        # 'exit' MUST come last, so do not even think about grabbing
        # them until @new is empty.
        # Micro-optimization, 'exit' only ever has 1 thing, so do
        # not enter the subs if we do not need to.
        push @new => $self->_poll_exit($check->() // last) if !@new && defined $self->{+_EXIT_BUFFER};

        last unless @new;

        push @out => @new;
        @new = ();
    }

    return map {
        my $stamp = $_->{stamp} ? $self->{+LAST_STAMP} = $_->{stamp} : $self->{+LAST_STAMP};
        Test2::Harness::Event->new(stamp => $stamp, %{$_});
    } @out;
}

sub _poll_streams {
    my $self = shift;
    my ($max) = @_;

    my $ready = $self->{+_READY_BUFFER};
    return splice(@$ready, 0, $max) unless @$ready < $max;

    my $stdout        = $self->{+_STDOUT_BUFFER};
    my $stdout_cg     = $self->{+_STDOUT_CG} ||= [];
    my $stdout_params = {
        buffer        => $stdout,
        comment_group => $stdout_cg,
        tag           => 'STDOUT',
        debug         => 0,
        parser        => \&parse_stdout_tap,
        max           => $max,
    };

    my $stderr        = $self->{+_STDERR_BUFFER};
    my $stderr_cg     = $self->{+_STDERR_CG} ||= [];
    my $stderr_params = {
        buffer        => $stderr,
        comment_group => $stderr_cg,
        tag           => 'STDERR',
        debug         => 1,
        parser        => \&parse_stderr_tap,
        max           => $max,
    };

    my $out_event = $self->_poll_stream($stdout_params);
    my $err_event = $self->_poll_stream($stderr_params);

    # Once both stderr and stdout are waiting for an event we should go ahead
    # and stick the events into ready. More often than not both streams will be
    # waiting for the same event, the read_buffer_event logic will avoid
    # duplicates. We want to call it on both buffers because some IPC
    # situations can result in both streams waiting for different events. Also
    # we need the sync point removed from both buffers so things can continue.
    # This is an intentional bottle-neck that keeps STDOUT, STDERR, and the
    # Test2 events in sync so that stderr and stdout appear where they should
    # (mostly) relative to the events. This is not perfect, but it is as close
    # as we can get when recombining 3+ output streams.
    if ($out_event && $err_event) {
        $self->_poll_streams_ready_buffer_event($stdout);
        $self->_poll_streams_ready_buffer_event($stderr);
    }

    if ($self->{+_EXIT_DONE} && (!$max || @$ready < $max)) {
        # All done, flush the comment groups
        $self->_poll_stream_flush_group($stdout_params) if @$stdout_cg;
        $self->_poll_stream_flush_group($stderr_params) if @$stderr_cg;

        $self->_poll_streams_flush_events();
    }

    return splice(@$ready, 0, $max);
}

sub _poll_streams_flush_events {
    my $self = shift;

    my $buffers = $self->{+_EVENTS_BUFFER};
    for my $pid (keys %$buffers) {
        for my $tid (keys %{$buffers->{$pid}}) {
            my $buffer = $buffers->{$pid}->{$tid} or next;
            while(my $e = shift @$buffer) {
                $e = ref($e) ? $e : decode_json($e);
                push @{$self->{+_READY_BUFFER}} => $self->_process_events_line($e);
            }
        }
    }
}

sub _poll_streams_ready_buffer_event {
    my $self = shift;
    my ($buffer) = @_;

    my $set = shift @$buffer;
    my ($pid, $tid, $sid) = @$set;

    my $seen = $self->{+_EVENTS_SEEN};
    return if $seen->{$tid}->{$pid}->{$sid};

    my $e = shift @{$self->{+_EVENTS_BUFFER}->{$pid}->{$tid}} or return;
    $seen->{$tid}->{$pid}->{$sid} = 1;

    $e = ref($e) ? $e : decode_json($e);

    die "Stream error: Events skipped or recieved out of order ($e->{stream_id} != $sid)"
        if $e->{stream_id} != $sid;

    push @{$self->{+_READY_BUFFER}} => $self->_process_events_line($e);
}

sub _poll_stream_add_event {
    my $self = shift;
    my ($line, $params) = @_;

    my $parser = $params->{parser};
    my $tag    = $params->{tag};
    my $debug  = $params->{debug};

    my $facet_data = $parser->($line);
    $facet_data ||= {info => [{details => $line, tag => $tag, debug => $debug}]};
    my $event_id = $facet_data->{about}->{uuid} ||= gen_uuid();

    push @{$self->{+_READY_BUFFER}} => {
        facet_data => $facet_data,
        event_id   => $event_id,
        job_id     => $self->{+JOB_ID},
        run_id     => $self->{+RUN_ID},
    };
}

sub _poll_stream_flush_group {
    my $self = shift;
    my ($params) = @_;

    my $comment_group = $params->{comment_group};

    return unless @$comment_group;

    shift @$comment_group;    # Remove the indentation state

    my $line = join "\n" => @$comment_group;
    $self->_poll_stream_add_event($line, $params);
    @$comment_group = ();
}

sub _poll_stream_buffer_group {
    my $self = shift;
    my ($line, $params) = @_;

    return undef unless $line =~ m/^(\s*)#/;
    my $indent = $1;

    my $comment_group = $params->{comment_group};

    if (@$comment_group && $comment_group->[0] ne $indent) {
        # If comment indentation has changed we do not want to append to the group
        $self->_poll_stream_flush_group($params);
        return 1;
    }
    else {
        # Starting a new group
        push @$comment_group => $indent;
    }

    push @$comment_group => $line;
    shift @{$params->{buffer}};
    return 0;
}

sub _poll_stream {
    my $self = shift;
    my ($params) = @_;

    my $max           = $params->{max};
    my $buff          = $params->{buffer};
    my $comment_group = $params->{comment_group};

    my $added = 0;
    while (@$buff && (!$max || $added < $max)) {
        my $line = $buff->[0];

        # Already have an esync waiting
        return 1 if ref $line;

        chomp($line);

        my $esync = $self->_poll_stream_process_harness_line($line, $params);
        return 1 if $esync;

        # Put 'comment' lines together in a group, IE buffer this until we are done with comments
        # get undef if there was no comment to buffer
        # get 1 if we had to flush the buffer and start a new one
        # get 0 if we did buffer the event, but no flush
        my $stat = $self->_poll_stream_buffer_group($line, $params);
        if (defined($stat)) {
            $added += $stat;
            next;
        }

        # non-comment line, flush the comment group
        if (@$comment_group) {
            $self->_poll_stream_flush_group($params);
            $added++;
            next;
        }

        shift @$buff;
        $self->_poll_stream_add_event($line, $params);
        $added++;
    }

    return 0;
}

sub _poll_stream_process_harness_line {
    my $self = shift;
    my ($line, $params) = @_;

    return undef unless $line =~ s/T2-HARNESS-(ESYNC|EVENT): (.+)//;
    my ($type, $data) = ($1, $2);

    my $esync;
    if ($type eq 'ESYNC') {
        $esync = [split ipc_separator() => $data];
    }
    elsif ($type eq 'EVENT') {
        my $event_data = decode_json($data);
        my $pid        = $event_data->{pid};
        my $tid        = $event_data->{tid};
        my $sid        = $event_data->{stream_id};

        push @{$self->{+_EVENTS_BUFFER}->{$pid}->{$tid}} => $event_data;
        $esync = [$pid, $tid, $sid];
    }
    else {
        die "Unexpected harness type: $type";
    }

    # This becomes the esync, anything leftover actually belongs to the
    # next line.
    my $buff = $params->{buffer};
    $buff->[0] = $esync;
    $buff->[1] = defined($buff->[1]) ? $line . $buff->[1] : $line if length $line;

    # Flush any comment group already buffered, an event is a sane
    # boundary, not above that partial comments that might be
    # interrupted by the sync point will be part of the next group
    $self->_poll_stream_flush_group($params);

    return $esync;
}

sub file {
    my $self = shift;
    return $self->{+_FILE} if $self->{+_FILE};

    my $fh = $self->_open_file('file');
    return 'UNKNOWN' unless $fh->exists;

    return $self->{+_FILE} = $fh->read_line;
}

my %FILE_MAP = (
    'stdout' => [STDOUT_FILE, \&open_file],
    'stderr' => [STDERR_FILE, \&open_file],
    'start'  => [START_FILE,  'Test2::Harness::Util::File::Value'],
    'exit'   => [EXIT_FILE,   'Test2::Harness::Util::File::Value'],
    'file'   => [FILE_FILE,   'Test2::Harness::Util::File::Value'],
);

sub _open_file {
    my $self = shift;
    my ($file) = @_;

    my $map = $FILE_MAP{$file} or croak "'$file' is not a known job file";
    my ($key, $type) = @$map;

    return $self->{$key} if $self->{$key};

    my $path = File::Spec->catfile($self->{+JOB_ROOT}, $file);
    my $out;

    return $self->{$key} = $type->new(name => $path)
        unless ref $type;

    return undef unless -e $path;
    return $self->{$key} = $type->($path, '<:utf8');
}

sub _fill_stream_buffers {
    my $self = shift;
    my ($max) = @_;

    my $stdout_buff = $self->{+_STDOUT_BUFFER} ||= [];
    my $stderr_buff = $self->{+_STDERR_BUFFER} ||= [];

    my $stdout_file = $self->{+STDOUT_FILE} || $self->_open_file('stdout');
    my $stderr_file = $self->{+STDERR_FILE} || $self->_open_file('stderr');

    my @sets = grep { defined $_->[0] } (
        [$stdout_file, $stdout_buff],
        [$stderr_file, $stderr_buff],
    );

    return unless @sets;

    # Cache the result of the exists check on success, files can come into
    # existence at any time though so continue to check if it fails.
    while (1) {
        my $added        = 0;
        my @events_files = $self->events_files();
        for my $set (@events_files, @sets) {
            my ($file, $buff) = @$set;
            next if $max && @$buff > $max;

            my $pos  = tell($file);
            my $line = <$file>;
            if (defined($line) && ($self->{+_EXIT_DONE} || substr($line, -1) eq "\n")) {
                push @$buff => $line;
                seek($file, 0, 1) if eof($file);    # Reset EOF.
                $added++;
            }
            else {
                seek($file, $pos, 0);
            }
        }
        last unless $added;
    }
}

sub events_files {
    my $self = shift;

    my $buff  = $self->{+_EVENTS_BUFFER} ||= {};
    my $files = $self->{+_EVENTS_FILES}  ||= {};

    my $dir = File::Spec->catfile($self->{+JOB_ROOT}, 'events');
    return unless -d $dir;

    opendir(my $dh, $dir) or die "Could not open events dir: $!";
    for my $file (readdir($dh)) {
        next unless '.jsonl' eq substr($file, -6);
        $files->{$file} ||= [
            split(ipc_separator() => substr(substr($file, 6 + length(ipc_separator())), 0, -6)),
            open_file(File::Spec->catfile($dir, $file), '<:utf8'),
        ];
    }

    return map { [$_->[2] => $buff->{$_->[0]}->{$_->[1]} ||= []] } values %$files;
}

sub _fill_buffers {
    my $self = shift;
    my ($max) = @_;
    # NOTE 1: 'max' will only effect stdout, stderr, and events.jsonl, the
    # other files only have 1 value each so they will not eat too much memory.
    #
    # NOTE 2: 'max' only effects how many items are ADDED to the buffer, not
    # how many are in the buffer, that is good enough, poll() will take care of
    # the actual event limiting. We only use this here to make sure the buffer
    # grows slowly, this is important if max is used to avoid eating memory. We
    # still need to add to the buffers each time though in case we are waiting
    # for a sync event before we flush.

    # Do not read anything until the start file is present and read.
    unless ($self->{+START_EXISTS}) {
        my $start_file = $self->{+START_FILE} || $self->_open_file('start');
        return unless $start_file->exists;
        $self->{+_START_BUFFER} = $start_file->read_line or return;
        $self->{+START_EXISTS} = 1;
    }

    $self->_fill_stream_buffers($max);

    # Do not look for exit until we are done with the other streams
    return if $self->{+_EXIT_DONE} || @{$self->{+_STDOUT_BUFFER}} || @{$self->{+_STDERR_BUFFER}} || first { @$_ } map { values %{$_} } values %{$self->{+_EVENTS_BUFFER}};

    my $ended = 0;
    my $exit_file = $self->{+EXIT_FILE} || $self->_open_file('exit');

    if ($exit_file->exists) {
        my $line = $exit_file->read_line;
        if (defined($line)) {
            $self->{+_EXIT_BUFFER} = $line;
            $self->{+_EXIT_DONE}   = 1;
            $ended++;
        }
    }
    elsif ($self->{+RUNNER_EXITED}) {
        $self->{+_EXIT_BUFFER} = '-1';
        $self->{+_EXIT_DONE}   = 1;
        $ended++;
    }

    return unless $ended;

    # If we found exit we need one last buffer fill on the other sources.
    # If we do not do this we have a race condition. Ignore the max for this.
    $self->_fill_stream_buffers();
}

sub _poll_start {
    my $self = shift;
    # Intentionally ignoring the max argument, this only ever returns 1 item,
    # and would not be called if max was 0.

    return unless defined $self->{+_START_BUFFER};
    my $value = delete $self->{+_START_BUFFER};

    return $self->_process_start_line($value);
}

sub _poll_exit {
    my $self = shift;
    # Intentionally ignoring the max argument, this only ever returns 1 item,
    # and would not be called if max was 0.

    return unless defined $self->{+_EXIT_BUFFER};
    my $value = delete $self->{+_EXIT_BUFFER};

    return $self->_process_exit_line($value);
}

sub _process_events_line {
    my $self = shift;
    my ($event_data) = @_;

    $event_data->{job_id} = $self->{+JOB_ID};
    $event_data->{run_id} = $self->{+RUN_ID};
    $event_data->{event_id} ||= $event_data->{facet_data}->{about}->{uuid} ||= gen_uuid();

    return $event_data;
}

sub _process_start_line {
    my $self = shift;
    my ($value) = @_;

    chomp($value);

    my $event_id = gen_uuid();

    $self->{+LAST_STAMP} = $value;

    return {
        event_id => $event_id,
        job_id   => $self->{+JOB_ID},
        run_id   => $self->{+RUN_ID},
        stamp    => $value,

        facet_data => {
            about             => {uuid => $event_id},
            harness_job_start => {
                details => "Job $self->{+JOB_ID} started at $value",
                job_id  => $self->{+JOB_ID},
                stamp   => $value,
                file    => $self->file,
                rel_file => File::Spec->abs2rel($self->file),
                abs_file => File::Spec->rel2abs($self->file),
            },
        }
    };
}

sub _process_exit_line {
    my $self = shift;
    my ($value) = @_;

    chomp($value);

    my $stdout = maybe_read_file(File::Spec->catfile($self->{+JOB_ROOT}, "stdout"));
    my $stderr = maybe_read_file(File::Spec->catfile($self->{+JOB_ROOT}, "stderr"));

    my $event_id = gen_uuid();

    my ($exit, $stamp) = split /\s+/, $value, 2;

    return {
        event_id => $event_id,
        job_id   => $self->{+JOB_ID},
        run_id   => $self->{+RUN_ID},
        stamp    => $stamp,

        facet_data => {
            about            => {uuid => $event_id},
            harness_job_exit => {
                details => "Test script exited $value",
                exit    => $exit,
                job_id  => $self->{+JOB_ID},
                file    => $self->file,
                stdout  => $stdout,
                stderr  => $stderr,
                stamp   => $stamp,
                line    => $value,
            },
        }
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Job::Dir - Job Directory Parser, read events from an active
jobs output directory.

=head1 DESCRIPTION

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
