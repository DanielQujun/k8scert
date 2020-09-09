#!/usr/bin/env bash
set -e

### 此脚本用户更新k8s证书以及harbor证书,需要在master节点上执行
### Usage:
### k8s_ca_update.sh <k8s|harbor>
###
### Options:
###   k8s: 更新k8s的根证书，只实现了续签功能
### 　harbor: 使用k8s的根证书签发新的harbor证书

K8S_PATH=/etc/kubernetes
PKI_PATH=${K8S_PATH}/pki
OLD_CRT=${PKI_PATH}/ca.pem
OLD_KEY=${PKI_PATH}/ca-key.pem

NEW_CRT_NAME=newca


EXPIRE_DAYS=36500


workdir=$(cd $(dirname $0); pwd)

newcrt_dir=${workdir}/newrootca

harbordir=${workdir}/harbor

script_name=$0



function backup_pki () {
   cp -ar ${PKI_PATH} ${workdir}/OLD_PKI
   ls ${workdir}/OLD_CONF >/dev/null 2>&1 || mkdir ${workdir}/OLD_CONF
   cp -ar ${K8S_PATH}/*conf ${workdir}/OLD_CONF
   cp -ar /root/.kube/config  ${workdir}/OLD_CONF
}


function find_all_hosts () {
  /usr/bin/kubectl get nodes  |grep -v NAME|awk '{print $1}' >${workdir}/all_hosts
}

function find_masters () {
  kubectl get nodes -l zone=master |grep -v NAME|awk '{print $1}' >${workdir}/master_hosts
}

function gen_new_crt () {
  ls ${newcrt_dir} 2>/dev/null|| mkdir -p ${newcrt_dir}

  serial=`openssl x509 -in ${OLD_CRT} -serial -noout | cut -f2 -d=`
  echo $serial

  openssl x509 -x509toreq -in ${OLD_CRT} -signkey ${OLD_KEY} -out ${newcrt_dir}/${NEW_CRT_NAME}.csr

  echo -e "[ v3_ca ]\nbasicConstraints= CA:TRUE\nsubjectKeyIdentifier= hash\nauthorityKeyIdentifier= keyid:always,issuer:always\n" > ${newcrt_dir}/${NEW_CRT_NAME}.conf

  openssl x509 -req -days ${EXPIRE_DAYS} -in ${newcrt_dir}/${NEW_CRT_NAME}.csr -set_serial 0x${serial} -signkey ${OLD_KEY} \
  -extfile ${newcrt_dir}/${NEW_CRT_NAME}.conf -extensions v3_ca -out ${newcrt_dir}/${NEW_CRT_NAME}.crt
}


function validate_date () {
  openssl x509 -in ${newcrt_dir}/${NEW_CRT_NAME}.crt -enddate -serial -noout

}

# 更新所有节点上的CA根证书
function update_root_ca () {
  for host in `cat ${workdir}/all_hosts`
  do
    scp ${workdir}/newrootca/${NEW_CRT_NAME}.crt root@${host}:/etc/kubernetes/pki/ca.pem
  done
}


function replace_conf () {

 k8s_conf=$1
 base64_encoded_ca="$(base64 ${workdir}/newrootca/${NEW_CRT_NAME}.crt )"

 # 在编码后直接替换换行符不生效，需要单独在替换一次
 base64_encoded_ca="$(echo -n ${base64_encoded_ca}|sed 's/ //g')"

/bin/sed "s/\(certificate-authority-data:\).*/\1 ${base64_encoded_ca}/" ${k8s_conf}

}

function replace_all_conf () {
  for conf in kubelet.conf scheduler.conf manager.conf
    do
      replace_conf ${K8S_PATH}/${conf}
    done

    ls /root/.kube/config >/dev/null 2>&1
    if [[ $? == 0 ]]; then
      replace_conf /root/.kube/config
    fi
}

function sync_conf () {
  for host in `cat ${workdir}/all_hosts`
    do
      for conf in kubelet.conf scheduler.conf manager.conf; do
       scp -rp ${K8S_PATH}/${conf} root@${host}:${K8S_PATH}/${conf}
      done
     done

   for master in `cat ${workdir}/master_hosts`; do
     scp -rp /root/.kube/config root@${master}:/root/.kube/config
   done

}


function replace_sa_secret () {

   base64_encoded_ca="$(base64 ${workdir}/newrootca/${NEW_CRT_NAME}.crt)"

   # 在编码后直接替换换行符不生效，需要单独在替换一次
   base64_encoded_ca="$(echo -n ${base64_encoded_ca}|sed 's/ //g')"

  for namespace in $(kubectl get ns --no-headers | awk '{print $1}'); do
    for token in $(kubectl get secrets --namespace "$namespace" --field-selector type=kubernetes.io/service-account-token -o name); do
        kubectl get $token --namespace "$namespace" -o yaml | \
          /bin/sed "s/\(ca.crt:\).*/\1 ${base64_encoded_ca}/" | \
          kubectl apply -f -
    done
  done
      # 替换calico-kube-controller使用的etcd证书
      kubectl get secret/steamer-etcd-secrets --namespace kube-system -o yaml | \
        /bin/sed "s/\(ca.pem:\).*/\1 ${base64_encoded_ca}/" | \
              kubectl apply -f -


}

function restart_controlplan () {
  for container in kube-apiserver kube-controller-manager kube-scheduler; do docker restart $(docker ps |grep k8s_${container}|awk '{print $1}') ; done

  systemctl restart etcd
}

function restart_all_controlplan () {
  for master in `cat ${workdir}/master_hosts`; do
    scp ${script_name} root@${master}:/tmp/
    ssh root@${master} "source /tmp/${script_name} && restart_controlplan"
  done

}

function restart_kubelet () {
  for host in `cat ${workdir}/all_hosts`; do

  ssh root@${host} "systemctl restart kubelet"
  done

}


function check_k8s_services () {
  for master in `cat ${workdir}/master_hosts`; do
  for master_etcd in `cat ${workdir}/master_hosts`; do
    ssh root@${master} "curl -s --cacert /etc/kubernetes/pki/ca.pem --cert /etc/kubernetes/pki/server/server.pem \
  --key /etc/kubernetes/pki/server/server-key.pem -X GET https://${master_etcd}:4001/v2/members"

    if [[ $? != 0 ]]; then
      echo "${master} check ${master_etcd} etcd Failed!!"
    fi
  done
  done

  for host in `cat ${workdir}/all_hosts`; do

    for apiserver in `cat ${workdir}/master_hosts`; do
       ssh root@${host} "curl -s --cacert /etc/kubernetes/pki/ca.pem https://${apiserver}:6443"
       if [[ $? != 0 ]]; then
          echo "${host} connect ${apiserver} apiserver Failed!!"
       fi
   done
  done

  for host in `cat ${workdir}/all_hosts`; do
  count=$(ssh root@${host} "curl -sk http://localhost:10255/metrics |grep -i rest_client_requests_total  |grep error |wc -l")
  if [[ $? != 0 ]]; then
    echo "${host} kubelet health check FAILED!!"
  fi
  if [[ ${count} != 0 ]]; then
    echo "${host} kubelet rest client request failed!!"
  fi
  done

}

# 此处开始harbor证书处理逻辑

function gen_harbor_crt () {

  ls ${harbordir} 2>/dev/null|| mkdir -p ${harbordir}

  cat << EOF > ${workdir}/harbor/harbor.conf
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[ dn ]
CN = hub.tiduyun.com

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = hub.tiduyun.com
IP.1 = __MASTER1__
IP.2 = __MASTER2__
IP.3 = __MASTER3__

[ v3_ext ]
authorityKeyIdentifier=keyid,issuer:always
basicConstraints=CA:FALSE
keyUsage=keyEncipherment,dataEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=@alt_names
EOF

seq_num=1
for master in `cat ${workdir}/master_hosts`
do
  sed -i "s/__MASTER${seq_num}/${master}/g" ${workdir}/harbor/harbor.conf
  ((seq_num++))
done


openssl genrsa -out ${harbordir}/harbor.key 2048

openssl req -new -key ${harbordir}/harbor.key -out ${harbordir}/harbor.csr -config ${harbordir}/harbor.conf

 openssl x509 -req -in ${harbordir}/harbor.csr -CA ${PKI_PATH}/ca.pem -CAkey ${PKI_PATH}/ca-key.pem \
 -CAcreateserial -out ${harbordir}/harbor.crt -days ${EXPIRE_DAYS}  -extensions v3_ext -extfile ${harbordir}/harbor.conf

}

function replace_harbor_crt () {

kubectl create secret generic tidu-harbor-nginx -n kube-system \
--from-file=ca.crt=${PKI_PATH}/ca.pem  \
--from-file=tls.crt=${harbordir}/harbor.crt \
--from-file=tls.key=${harbordir}/harbor.key  -o yaml --dry-run  |kubectl apply -f -

}

function sync_docker_client_crt () {
  for host in `cat ${workdir}/all_hosts`; do
      scp -rp ${PKI_PATH}/ca.pem root@${host}:/etc/docker/certs.d/hub.tiduyun.com:5000/ca.crt
  done
}

function restart_harbor_service () {
kubectl delete po -n kube-system -l component=nginx
kubectl delete po -n kube-system -l component=core
}


function check_harbor_service () {
  for host in `cat ${workdir}/all_hosts`; do
    docker login hub.tiduyun.com:5000 -u admin -p Harbor12345 1>/dev/null 2>&1
    if [[ $? != 0 ]]; then
      echo "${host} login harbor FAILED!!"
    fi
  done

}


function root_ca () {

ls ${workdir}/all_hosts > /dev/null 2>&1|| find_all_hosts
ls ${workdir}/master_hosts >/dev/null 2>&1 || find_masters
backup_pki

gen_new_crt

validate_date

update_root_ca

replace_all_conf

sync_conf

replace_sa_secret

restart_all_controlplan

restart_kubelet

sleep 10

check_k8s_services

}

function harbor_ca () {
ls ${workdir}/all_hosts > /dev/null 2>&1|| find_all_hosts
ls ${workdir}/master_hosts >/dev/null 2>&1 || find_masters

gen_harbor_crt

replace_harbor_crt
sync_docker_client_crt
restart_harbor_service
sleep 10
check_harbor_service
}

function main () {

  action=$1

  case $action in
  k8s) root_ca
  ;;
  harbor) harbor_ca
  ;;
  help|?|-h) help
  ;;
  esac
}

function help () {
	awk -F'### ' '/^###/ { print $2 }' "$0"
}

action=$1

main ${action}