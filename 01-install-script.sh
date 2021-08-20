#!/bin/bash
set -xe

# create a cluster, if you need one: gcloud container clusters create jesse-gke5 --num-nodes=1

# get kube-dns clusterIP
KUBEDNS=`kubectl get svc kube-dns -n kube-system -o jsonpath={.spec.clusterIP}`
sed -i "s/kube-dns-ip/$KUBEDNS/g" ./values-plus.yaml

# install kic 
helm repo add nginx-stable https://helm.nginx.com/stable
helm repo update
helm install plus nginx-stable/nginx-ingress -f values-plus.yaml --namespace nginx-ingress --create-namespace


# pod needs to be ready before we should look for external IP
while [ "$(kubectl get pods -A -l=app='plus-nginx-ingress' -o jsonpath='{.items[*].status.containerStatuses[0].ready}')" != "true" ]; do
   sleep 1
   echo "Waiting for kic to be ready."
done
EXTERNALIP="TBD"
while [ "$EXTERNALIP" = "TBD" ]
do
    # make sure we get an IP
    IP=`kubectl get services --namespace nginx-ingress plus-nginx-ingress --output jsonpath='{.status.loadBalancer.ingress[0].ip}'`
    echo $IP
    [[ "$IP" =~ ^(([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$ ]] && EXTERNALIP=$IP || echo "invalid"
    sleep 1
done
echo $EXTERNALIP

gcloud dns record-sets \
    update keycloak.nginx.rocks \
    --rrdatas="$EXTERNALIP" \
    --type=A --ttl=30 --zone=nginx-rocks

gcloud dns record-sets \
    update webapp.nginx.rocks \
    --rrdatas="$EXTERNALIP" \
    --type=A --ttl=30 --zone=nginx-rocks

kubectl apply -f ./nginx-ingress-headless.yaml
kubectl apply -f ./keycloak
KEYCLOAK_ADDRESS=keycloak.nginx.rocks

# wait for keycloak to be availible
until $(curl -k --output /dev/null --silent --head --fail https://$KEYCLOAK_ADDRESS); do
    sleep 1
    kubectl get pods -n keycloak
done

TOKEN=`curl -sS -k --data "username=admin&password=admin&grant_type=password&client_id=admin-cli" https://${KEYCLOAK_ADDRESS}/auth/realms/master/protocol/openid-connect/token | jq -r .access_token`
echo $TOKEN

# create nginx-user
curl -sS -k -X POST -d '{ "username": "nginx-user", "enabled": true, "credentials":[{"type": "password", "value": "test", "temporary": false}]}' -H "Content-Type:application/json" -H "Authorization: bearer ${TOKEN}" https://${KEYCLOAK_ADDRESS}/auth/admin/realms/master/users

# create oidc client
NEWCLIENT=`curl -sS -k -X POST -d '{ "clientId": "nginx-plus", "redirectUris": ["https://webapp.nginx.rocks:443/_codexch"] }' -H "Content-Type:application/json" -H "Authorization: bearer ${TOKEN}" https://${KEYCLOAK_ADDRESS}/auth/realms/master/clients-registrations/default`
echo $NEWCLIENT
SECRET=`echo $NEWCLIENT | jq -r .secret`
echo $SECRET
echo "client secret:"
echo -n $SECRET|base64
SECRETB64=`echo -n $SECRET|base64`
sed -i "s/SECRETKEY/$SECRETB64/g" ./webapp/oidc.yaml

# create the app and oidc config
kubectl apply -f ./webapp
