package presque::RestQueueHandler;

use 5.010;

use JSON;
use Moose;
extends 'Tatsumaki::Handler';
with
  'presque::Role::Queue::Names',
  'presque::Role::Error', 'presque::Role::Response', 'presque::Role::Queue',
  'presque::Role::Queue::WithContent'   => {methods => [qw/put post/]},
  'presque::Role::Queue::WithQueueName' => {methods => [qw/get delete/]};

__PACKAGE__->asynchronous(1);

sub get    { (shift)->_is_queue_opened(shift) }
sub post   { (shift)->_create_job(shift) }
sub put    { (shift)->_failed_job(shift) }
sub delete { (shift)->_purge_queue(shift) }

sub _is_queue_opened {
    my ($self, $queue_name) = @_;

    $self->application->redis->get(
        $self->_queue_stat($queue_name),
        sub {
            my $status = shift;
            if (defined $status && $status == 0) {
                return $self->http_error_queue_is_closed();
            }else{
                return $self->_fetch_job($queue_name);
            }
        }
    );
}

sub _fetch_job {
    my ($self, $queue_name) = @_;

    my $lkey = $self->_queue($queue_name);

    $self->application->redis->lpop(
        $lkey,
        sub {
            my $value = shift;
            if ($value) {
                $self->application->redis->get(
                    $value,
                    sub {
                        my $job = shift;
                        $self->application->redis->del($value);
                        $self->_finish_get($queue_name, $job, $value);
                    }
                );
            }
            else {
                $self->http_error('no job', 404);
            }
        }
    );
}

sub _finish_get {
    my ($self, $queue_name, $job, $key) = @_;

    $self->_remove_from_uniq($queue_name, $key);
    $self->_update_queue_stats($queue_name, $job);
    $self->_update_worker_stats($queue_name, $job);
    $self->finish($job);
}

sub _remove_from_uniq {
    my ($self, $queue_name, $key) = @_;

    my @keys = (ref $key) ? @$key : ($key);
    $self->application->redis->hmget(
        $self->_queue_uniq_revert($queue_name),
        @keys,
        sub {
            my $value = shift;
            for my $i (0 .. (@$value - 1)) {
                if (my $key = $value->[$i]) {
                    $self->application->redis->hdel(
                        $self->_queue_uniq($queue_name), $key);
                    $self->application->redis->hdel(
                        $self->_queue_uniq_revert($queue_name),
                        $keys[$i]);
                }
            }
        }
    );
}

sub _update_queue_stats {
    my ($self, $queue_name) = @_;

    $self->application->redis->hincrby($self->_queue_processed, $queue_name,
        1);
}

sub _update_worker_stats {
    my ($self, $queue_name) = @_;

    my $worker_id = $self->request->header('X-presque-workerid');

    if ($worker_id) {
        $self->application->redis->hincrby($self->_workers_processed,
            $worker_id, 1);
    }
}

sub _create_job {
    my ($self, $queue_name) = @_;

    my $p = $self->request->content;

    my $input   = $self->request->parameters;
    my $delayed = ($input && $input->{delayed}) ? $input->{delayed} : undef;
    my $uniq    = ($input && $input->{uniq}) ? $input->{uniq} : undef;

    if ($uniq) {
        $self->application->redis->hexists(
            $self->_queue_uniq($queue_name),
            $uniq,
            sub {
                my $status = shift;
                if ($status == 0) {
                    $self->_insert_to_queue($queue_name, $p, $delayed, $uniq);
                }
                else {
                    $self->http_error('job already exists');
                }
            }
        );
    }
    else {
        $self->_insert_to_queue($queue_name, $p, $delayed);
    }
}

sub _insert_to_queue {
    my ($self, $queue_name, $p, $delayed, $uniq) = @_;

    $self->application->redis->incr(
        $self->_queue_uuid($queue_name),
        sub {
            my $uuid = shift;
            my $key = $self->_queue_key($queue_name, $uuid);

            $self->application->redis->set(
                $key, $p,
                sub {
                    my $status_set = shift;
                    my $lkey       = $self->_queue($queue_name);
                    $self->new_queue($queue_name, $lkey) if ($uuid == 1);
                    if ($uniq) {
                        $self->application->redis->hset($self->_queue_uniq($queue_name), $uniq, $key);
                        $self->application->redis->hset($self->_queue_uniq_revert($queue_name), $key, $uniq);
                    }
                    $self->_finish_post($lkey, $key, $status_set, $delayed,
                            $queue_name);
                }
            );
        }
    );
}

sub _failed_job {
    my ($self, $queue_name) = @_;

    my $worker_id = $self->request->header('X-presque-workerid')
      if $self->request->header('X-presque-workerid');

    $self->application->redis->hincrby($self->_queue_failed, $queue_name, 1);

    if ($worker_id) {
        $self->application->redis->hincrby($self->_workers_failed($worker_id), 1);
    }

    $self->_create_job($queue_name);
}

sub _purge_queue {
    my ($self, $queue_name) = @_;

    # supprimer tous les jobs

    $self->application->redis->llen(
        $self->_queue($queue_name),
        sub {
            my $size = shift;
            $self->application->redis->lrange(
                $self->_queue($queue_name),
                0, $size,
                sub {
                    my $jobs = shift;
                    foreach my $j (@$jobs) {
                        $self->application->redis->del($j);
                    }
                    $self->application->redis->del($self->_queue($queue_name));
                }
            );
        }
    );


    $self->application->redis->del($self->_queue_delayed($queue_name));
    $self->application->redis->del($self->_queue_uniq($queue_name));
    $self->application->redis->del($self->_queue_uniq_revert($queue_name));
    $self->application->redis->hdel($self->_queue_processed, $queue_name);
    $self->application->redis->hdel($self->_queue_failed,    $queue_name);

    $self->response->code(204);
    $self->finish();
}

sub _finish_post {
    my ($self, $lkey, $key, $result, $delayed, $queue_name) = @_;

    $self->push_job($queue_name, $lkey, $key, $delayed);
    $self->response->code(201);
    $self->finish();
}

1;
__END__

=head1 NAME

presque::RestQueueHandler

=head1 SYNOPSIS

    # insert a new job
    curl -H 'Content-Type: application/json' -X POST "http://localhost:5000/q/foo" -d '{"key":"value"}'

    # insert a delayed job
    curl -H 'Content-Type: application/json' -X POST "http://localhost:5000/q/foo?delayed="$(expr `date +%s` + 500) -d '{"key":"value"}'

    # fetch a job
    curl http://localhost:5000/q/foo

    # purge and delete all jobs for a queue
    curl -X DELETE http://localhost:5000/q/foo

=head1 DESCRIPTION

=head1 METHODS

=head2 get

=over 4

=item path

/q/:queue_name

=item headers

X-presque-workerid: worker's ID (optional)

=item request

queue_name: name of the queue to use (required)

=item response

If the queue is closed: 404

If no job is available in the queue: 404

If a job is available: 200

Content-Type: application/json

=back

If the queue is open, a job will be fetched from the queue and send to the client

=head2 post

=over 4

=item path

/q/:queue_name

=item headers

content-type: application/json

X-presque-workerid: worker's ID

=item request

content: JSON object

query: delayed, after which date (in epoch) this job should be run

uniq: this job is uniq. The value is the string that will be used to determined if the job is uniq

=item response

code: 201

content: null

=back

The B<Content-Type> of the request must be set to B<application/json>. The body of the request must be a valid JSON object.

It is possible to create delayed jobs (eg: job that will not be run before a defined time in the futur).

the B<delayed> value should be a date in epoch.

=head2 put

=over 4

=item path

/q/:queue_name

=item headers

X-presque-workerid: worker's id (optional)

=item response

code: 201

content: null

=back

=head2 delete

=over 4

=item path

/q/:queue_name

=item response

code: 204

content: null

=back

Purge and delete the queue.

=head1 AUTHOR

franck cuny E<lt>franck@lumberjaph.netE<gt>

=head1 SEE ALSO

=head1 LICENSE

Copyright 2010 by Linkfluence

L<http://linkfluence.net>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
