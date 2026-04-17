#!/bin/bash
mongodump --username taskyuser --password taskypassword --authenticationDatabase tasky --out /tmp/mongobackup
aws s3 cp /tmp/mongobackup s3://johnny-test-wiz-exercise-bucket/ --recursive
