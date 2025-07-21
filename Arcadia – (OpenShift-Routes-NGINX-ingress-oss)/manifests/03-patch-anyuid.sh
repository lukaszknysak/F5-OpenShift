#!/usr/bin/env bash
set -e
for d in main backend app2 app3; do
  oc patch deployment $d -n arcadia -p '{"spec":{"template":{"spec":{"serviceAccountName":"arcadia-anyuid"}}}}'
done