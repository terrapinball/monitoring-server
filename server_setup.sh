#!/bin/bash

terraform apply -auto-approve
host_ip=$(terraform output -raw host_ip)
retry=0
until ssh ec2-user@$host_ip "ls" > /dev/null
    do
        (( retry++ ))
        if [[ $retry > 5 ]]
        then
            echo "Connection failed. Ensure ec2 instance has started properly."
            exit 1
        fi
        sleep 5
        echo "Retrying connection to db... (Attempt $retry of 5)"
    done
echo "Connecting to ec2 instance..."
ssh -t ec2-user@$host_ip screen -R