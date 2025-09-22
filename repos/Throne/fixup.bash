#!/usr/bin/env bash

curl -fLso srslist.h \
    "https://raw.githubusercontent.com/throneproj/routeprofiles/rule-set/srslist.h"

mv srslist.h ./*/
