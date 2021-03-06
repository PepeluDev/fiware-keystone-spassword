#!/bin/bash

KEYSTONE_ADMIN_PASSWORD=4pass1w0rd
MYSQL_ROOT_PASSWORD="iotonpremise"

DB_HOST_ARG=${1}
# DB_HOST_VALUE can be hostname[:port]
DB_HOST_VALUE=${2}
DB_HOST_NAME="$(echo "${DB_HOST_VALUE}" | awk -F: '{print $1}')"
DB_HOST_PORT="$(echo "${DB_HOST_VALUE}" | awk -F: '{print $2}')"
# Default MySQL port 3306
[[ "${DB_HOST_PORT}" == "" ]] && DB_HOST_PORT=3306

DEFAULT_PASSWORD_ARG=${3}
DEFAULT_PASSWORD_VALUE=${4}

MYSQL_PASSWORD_ARG=${5}
MYSQL_PASSWORD_VALUE=${6}

if [ "$DEFAULT_PASSWORD_ARG" == "-default_pwd" ]; then
    KEYSTONE_ADMIN_PASSWORD=$DEFAULT_PASSWORD_VALUE
fi

if [ "$MYSQL_PASSWORD_ARG" == "-mysql_pwd" ]; then
    MYSQL_ROOT_PASSWORD="$MYSQL_PASSWORD_VALUE"
fi


if [ "$DB_HOST_ARG" == "-dbhost" ]; then
    openstack-config --set /etc/keystone/keystone.conf \
                     database connection mysql://keystone:keystone@$DB_HOST_NAME:$DB_HOST_PORT/keystone;
    # Ensure previous keystone database does not exist
    mysql -h $DB_HOST_NAME --port $DB_HOST_PORT -u root --password=$MYSQL_ROOT_PASSWORD <<EOF
DROP DATABASE keystone;
EOF
    mysql -h $DB_HOST_NAME --port $DB_HOST_PORT -u root --password=$MYSQL_ROOT_PASSWORD <<EOF
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' \
    IDENTIFIED BY 'keystone';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' \
    IDENTIFIED BY 'keystone';
EOF

fi

/usr/bin/keystone-manage db_sync
/usr/bin/keystone-manage db_sync --extension spassword

/usr/bin/keystone-all &
keystone_all_pid=`echo $!`
sleep 5

# Create Services

export OS_SERVICE_TOKEN=ADMIN
export OS_SERVICE_ENDPOINT=http://127.0.0.1:35357/v2.0
export KEYSTONE_HOST="127.0.0.1:5001"

keystone user-create --name=admin --pass=$KEYSTONE_ADMIN_PASSWORD --email=admin@no.com 
keystone role-create --name=admin
keystone tenant-create --name=admin --description="Admin Tenant"
keystone user-role-add --user=admin --tenant=admin --role=admin
keystone role-create --name=service
keystone user-create --name=iotagent --pass=$KEYSTONE_ADMIN_PASSWORD --email=iotagent@no.com
keystone user-create --name=nagios --pass=$KEYSTONE_ADMIN_PASSWORD --email=nagios@no.com
keystone user-role-add --user=nagios --tenant=admin --role=admin

IOTAGENT_ID=`keystone user-list | grep "iotagent" | awk '{print $2}'`

ADMIN_TOKEN=$(\
curl http://${KEYSTONE_HOST}/v3/auth/tokens   \
         -s                                   \
         -i                                   \
         -H "Content-Type: application/json"  \
         -d '
     {
      "auth": {
          "identity": {
              "methods": [
                  "password"
              ],
              "password": {
                  "user": {
                      "domain": {
                          "name": "Default"
                      },
                      "name": "admin",
                      "password": "'$KEYSTONE_ADMIN_PASSWORD'"
                  }
              }
          },
          "scope": {
              "project": {
                  "domain": {
                      "name": "Default"
                  },
                  "name": "admin"
              }
          }
      }
    }' | grep ^X-Subject-Token: | awk '{print $2}' )
echo "ADMIN_TOKEN: $ADMIN_TOKEN"

ID_ADMIN_DOMAIN=$(\
curl http://${KEYSTONE_HOST}/v3/domains          \
         -s                                      \
         -H "X-Auth-Token: $ADMIN_TOKEN"         \
         -H "Content-Type: application/json"     \
         -d '
  {
      "domain": {
      "enabled": true,
      "name": "admin_domain"
      }
  }' | jq .domain.id | tr -d '"' )
echo "ID_ADMIN_DOMAIN: $ID_ADMIN_DOMAIN"

ID_CLOUD_SERVICE=$(\
curl http://${KEYSTONE_HOST}/v3/users             \
         -s                                       \
         -H "X-Auth-Token: $ADMIN_TOKEN"          \
         -H "Content-Type: application/json"      \
         -d '
  {
      "user": {
          "description": "Cloud service",
          "domain_id": "'$ID_ADMIN_DOMAIN'",
          "enabled": true,
          "name": "pep",
          "password": "'$KEYSTONE_ADMIN_PASSWORD'"
      }
  }' | jq .user.id | tr -d '"' )
echo "ID_CLOUD_SERVICE: $ID_CLOUD_SERVICE"

ID_CLOUD_ADMIN=$(\
curl http://${KEYSTONE_HOST}/v3/users              \
         -s                                        \
         -H "X-Auth-Token: $ADMIN_TOKEN"           \
         -H "Content-Type: application/json"       \
         -d '
  {
      "user": {
          "description": "Cloud administrator",
          "domain_id": "'$ID_ADMIN_DOMAIN'",
          "enabled": true,
          "name": "cloud_admin",
          "password": "'$KEYSTONE_ADMIN_PASSWORD'"
      }
  }' | jq .user.id | tr -d '"' )
echo "ID_CLOUD_ADMIN: $ID_CLOUD_ADMIN"

ADMIN_ROLE_ID=$(\
curl "http://${KEYSTONE_HOST}/v3/roles?name=admin"  \
         -s                                         \
         -H "X-Auth-Token: $ADMIN_TOKEN" \
        | jq .roles[0].id | tr -d '"' )
echo "ADMIN_ROLE_ID: $ADMIN_ROLE_ID"

curl -X PUT http://${KEYSTONE_HOST}/v3/domains/${ID_ADMIN_DOMAIN}/users/${ID_CLOUD_ADMIN}/roles/${ADMIN_ROLE_ID} \
     -s                                 \
     -i                                 \
     -H "X-Auth-Token: $ADMIN_TOKEN"    \
     -H "Content-Type: application/json"

SERVICE_ROLE_ID=$(\
curl "http://${KEYSTONE_HOST}/v3/roles?name=service" \
         -s                                          \
         -H "X-Auth-Token: $ADMIN_TOKEN" \
        | jq .roles[0].id | tr -d '"' )
echo "SERVICE_ROLE_ID: $SERVICE_ROLE_ID"

curl -X PUT http://${KEYSTONE_HOST}/v3/domains/${ID_ADMIN_DOMAIN}/users/${ID_CLOUD_SERVICE}/roles/${SERVICE_ROLE_ID} \
      -s                                 \
      -i                                 \
      -H "X-Auth-Token: $ADMIN_TOKEN"    \
      -H "Content-Type: application/json"

curl -s -L --insecure https://github.com/openstack/keystone/raw/liberty-eol/etc/policy.v3cloudsample.json \
  | jq ' .["identity:scim_create_role"]="rule:cloud_admin or rule:admin_and_matching_domain_id"
     | .["identity:scim_list_roles"]="rule:cloud_admin or rule:admin_and_matching_domain_id"
     | .["identity:scim_get_role"]="rule:cloud_admin or rule:admin_and_matching_domain_id"
     | .["identity:scim_update_role"]="rule:cloud_admin or rule:admin_and_matching_domain_id"
     | .["identity:scim_delete_role"]="rule:cloud_admin or rule:admin_and_matching_domain_id"
     | .["identity:scim_get_service_provider_configs"]=""
     | .["identity:get_domain"]=""
     | .admin_and_user_filter="role:admin and \"%\":%(user.id)%"
     | .admin_and_project_filter="role:admin and \"%\":%(scope.project.id)%"
     | .["identity:list_role_assignments"]="rule:cloud_admin or rule:admin_on_domain_filter or rule:cloud_service or rule:admin_and_user_filter or rule:admin_and_project_filter"
     | .["identity:list_projects"]="rule:cloud_admin or rule:admin_and_matching_domain_id or rule:cloud_service"
     | .cloud_admin="rule:admin_required and domain_id:'${ID_ADMIN_DOMAIN}'"
     | .cloud_service="rule:service_role and domain_id:'${ID_ADMIN_DOMAIN}'"' \
  | tee /etc/keystone/policy.json

# Set another ADMIN TOKEN
openstack-config --set /etc/keystone/keystone.conf \
                 DEFAULT admin_token $KEYSTONE_ADMIN_PASSWORD

# Exclude some users from spassword
openstack-config --set /etc/keystone/keystone.conf \
                 spassword pwd_user_blacklist $ID_CLOUD_ADMIN,$ID_CLOUD_SERVICE,$IOTAGENT_ID

kill -9 $keystone_all_pid
sleep 3
chkconfig openstack-keystone on
