#!/bin/sh

SCENARIO=${1:-simple_foreign_event.erl}
AMOC_PORTS=( 4000 4001 4002 )

for PORT in ${AMOC_PORTS[@]}
do
    http POST "localhost:$PORT/scenarios" scenario=${SCENARIO/.erl/} module_source="$(cat $SCENARIO)"
done
