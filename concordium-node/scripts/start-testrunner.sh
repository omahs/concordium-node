#!/bin/bash

./target/release/testrunner --listen-port $LISTEN_PORT --listen-http-port $LISTEN_HTTP_PORT --bootstrap-server $BOOTSTRAP_FIRST_NODE --bootstrap-server $BOOTSTRAP_SECOND_NODE $EXTRA_ARGS 