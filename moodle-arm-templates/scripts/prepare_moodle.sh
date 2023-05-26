#!/bin/bash

set -ex

#functions
function get_setup_params_from_configs_json #modify to export only required variables
{
    local configs_json_path=${1}    # E.g., /var/lib/cloud/instance/moodle_on_azure_configs.json

    #(dpkg -l jq &> /dev/null) || (apt -y update; apt -y install jq)
    sudo add-apt-repository universe
    sudo apt-get -y update
    sudo apt-get -y install jq

    # Added curl command to download jq.
    #curl https://stedolan.github.io/jq/download/linux64/jq > /usr/bin/jq && chmod +x /usr/bin/jq
	
    # Wait for the cloud-init write-files user data file to be generated (just in case)
    local wait_time_sec=0
    while [ ! -f "$configs_json_path" ]; do
        sleep 15
        let "wait_time_sec += 15"
        if [ "$wait_time_sec" -ge "1800" ]; then
            echo "Error: Cloud-init write-files didn't complete in 30 minutes!"
            return 1
        fi
    done

    sudo chmod +r $configs_json_path
    local json=$(cat $configs_json_path)
    export storageAccountName=$(echo $json | jq -r .storageProfile.storageAccountName)
    export storageAccountKey=$(echo $json | jq -r .storageProfile.storageAccountKey)
    export phpVersion=$(echo $json | jq -r .moodleProfile.phpVersion)
    export SQLServerName=$(echo $json | jq -r .dbServerProfile.SQLServerName)
    export SQLServerAdmin=$(echo $json | jq -r .dbServerProfile.SQLServerAdmin)
    export SQLAdminPassword=$(echo $json | jq -r .dbServerProfile.SQLAdminPassword)
    export SQLDBName=$(echo $json | jq -r .dbServerProfile.SQLDBName)
    export exportDBname=$(echo $json | jq -r .dbServerProfile.exportDBname)
    export ACRname=$(echo $json | jq -r .acrProfile.ACRname)
    export ACRusername=$(echo $json | jq -r .acrProfile.ACRusername)
    export ACRtoken=$(echo $json | jq -r .acrProfile.ACRtoken)
    export base64AKScred=$(echo $json | jq -r .aksProfile.base64AKScred)
    export useAzureDisk=$(echo $json | jq -r .storageProfile.useAzureDisk)
    export fileServerDiskSize=$(echo $json | jq -r .storageProfile.fileServerDiskSize)

}

function check_azure_files_moodle_share_exists
{
    local storageAccountName=$1
    local storageAccountKey=$2

    local azResponse=$(az storage share exists --name aksshare --account-name $storageAccountName --account-key $storageAccountKey)
    if [ $? -ne 0 ];then
      echo "Could not check if moodle file share exists in the storage account ($storageAccountName)"
      exit 1
    fi

    echo "az storage share exists command response:"
    echo $azResponse
    #Sample 'az storage share exists' command response
    # { "exists": true }
    local exists=$(echo $azResponse | jq -r .exists)

    if [ "$exists" != "true" ];then
      echo "File share 'moodle' does not exists in the storage account ($storageAccountName)"
      exit 1
    fi
}

function setup_and_mount_azure_files_moodle_share
{
    local storageAccountName=$1
    local storageAccountKey=$2

    sudo chmod 777 /etc/

    cat <<EOF > /etc/moodle_azure_files.credential
username=$storageAccountName
password=$storageAccountKey
EOF
    sudo chmod 600 /etc/moodle_azure_files.credential

    storename="aksshare"
    sudo chmod 777 /etc/fstab
    grep -q -s "^//$storageAccountName.file.core.windows.net/$storename\s\s*/mountdir\s\s*cifs" /etc/fstab && _RET=$? || _RET=$?
    if [ $_RET != "0" ]; then
        echo -e "\n//$storageAccountName.file.core.windows.net/$storename   /mountdir cifs    credentials=/etc/moodle_azure_files.credential,nofail,serverino,mfsymlinks" >> /etc/fstab
    fi
    # create Azure Files mount point
    sudo mkdir -p /mountdir
    sudo chmod 777 /mountdir
    sudo mount /mountdir

}


#parameters 
moodle_on_azure_configs_json_path=${1}

get_setup_params_from_configs_json $moodle_on_azure_configs_json_path || exit 99

export DEBIAN_FRONTEND=noninteractive

# install cifs-utils
sudo apt-get -y update                                               
sudo apt-get -y --force-yes install cifs-utils                       

# install azure cli & setup container
AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" |  sudo tee /etc/apt/sources.list.d/azure-cli.list

curl -L https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add - 
sudo apt-get -y install apt-transport-https 
sudo apt-get -y update > /dev/null
sudo apt-get -y install azure-cli 

# mounting azure file share
# check if the moodle azure file share is present before running this script.
echo -e '\n\r check whether moodle fileshare exists\n\r'
check_azure_files_moodle_share_exists $storageAccountName $storageAccountKey

# Set up and mount Azure Files share.
echo -e '\n\rSetting up and mounting Azure Files share //'$storageAccountName'.file.core.windows.net/aksshare on /moodle\n\r'
setup_and_mount_azure_files_moodle_share $storageAccountName $storageAccountKey

#install kubectl
sudo chmod 777 /usr/local/bin
az aks install-cli                                         

#install and configure helm
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get-helm-3 > get_helm.sh
chmod 700 get_helm.sh
./get_helm.sh

#configure kubectl to use credentials for AKS cluster
sudo mkdir -p /home/azureadmin/.kube
sudo chmod 777 /home/azureadmin/.kube
echo $base64AKScred | base64 --decode > /home/azureadmin/.kube/config
sudo chmod 666 /home/azureadmin/.kube/config
export KUBECONFIG=/home/azureadmin/.kube/config  #custom script extension runs as root, so setting KUBECONFIG

#creating secret for storage account details
kubectl create secret generic az-secret --from-literal=azurestorageaccountname=$storageAccountName --from-literal=azurestorageaccountkey=$storageAccountKey

#modify storage to file server size before applying pv, pvc
sudo chmod 755 pv.yaml
sudo chmod 755 pvc.yaml
sudo chmod 755 disk-pvc.yaml
sudo sed -Ei 's/(100Gi)/'"$fileServerDiskSize"'Gi/g' pv.yaml
sudo sed -Ei 's/(100Gi)/'"$fileServerDiskSize"'Gi/g' pvc.yaml
sudo sed -Ei 's/(100Gi)/'"$fileServerDiskSize"'Gi/g' disk-pvc.yaml
#create persistentvolume and persistencevolumeclaim using kubectl(create pvc for azure disk if useAzureDisk is set to true)
kubectl apply -f pv.yaml
kubectl apply -f pvc.yaml
if [ "$useAzureDisk" = "true" ]; then
    kubectl apply -f disk-pvc.yaml
fi

#get mysqlclient
sudo apt-get -y --force-yes install mysql-client 

#get tar and unzip sql export file
sudo apt-get -y update  
sudo apt-get -y --force-yes install tar 
sudo tar -xvf /mountdir/$exportDBname.sql.tar.gz -C /mountdir 

#import sql to Azure SQL
mysql -h $SQLServerName -u $SQLServerAdmin -p$SQLAdminPassword -e "CREATE DATABASE $SQLDBName CHARACTER SET utf8;"
mysql -h $SQLServerName -u $SQLServerAdmin -p$SQLAdminPassword -e "GRANT ALL ON $SQLDBName.* TO '$SQLServerAdmin' IDENTIFIED BY '$SQLAdminPassword';"
mysql -h $SQLServerName -u $SQLServerAdmin -p$SQLAdminPassword $SQLDBName < /mountdir/$exportDBname.sql #figure out whats the deal with this path
mysql -h $SQLServerName -u $SQLServerAdmin -p$SQLAdminPassword -e "flush privileges;"

#editing moodle config
sudo chmod 777 /mountdir/moodle/
sudo sed -Ei 's/(\$CFG->dbtype)\s*=.*/$CFG->dbtype = '"'mysqli'"';/g' /mountdir/moodle/config.php
sudo sed -Ei 's/(\$CFG->dbhost)\s*=.*/$CFG->dbhost = '"'$SQLServerName'"';/g' /mountdir/moodle/config.php
sudo sed -Ei 's/(\$CFG->dbname)\s*=.*/$CFG->dbname = '"'$SQLDBName'"';/g' /mountdir/moodle/config.php
sudo sed -Ei 's/(\$CFG->dbuser)\s*=.*/$CFG->dbuser = '"'$SQLServerAdmin'"';/g' /mountdir/moodle/config.php
sudo sed -Ei 's/(\$CFG->dbpass)\s*=.*/$CFG->dbpass = '"'$SQLAdminPassword'"';/g' /mountdir/moodle/config.php
sudo sed -Ei "s/('dbport')\s*=.*/'dbport' => 3306,/g" /mountdir/moodle/config.php
sudo sed -Ei "s/('dbcollation')\s*=.*/'dbcollation' => 'utf8mb4_unicode_ci',/g" /mountdir/moodle/config.php
sudo sed -Ei 's/(\$CFG->dataroot)\s*=.*/$CFG->dataroot = '"'\/bitnami\/moodledata'"';/g' /mountdir/moodle/config.php
http_port="8080"
conf_to_replace="if (empty(\$_SERVER['HTTP_HOST'])) {\\
  \$_SERVER['HTTP_HOST'] = '127.0.0.1:${http_port}';\\
}\\
if (isset(\$_SERVER['HTTPS']) \&\& \$_SERVER['HTTPS'] == 'on') {\\
  \$CFG->wwwroot   = 'https:\/\/' . \$_SERVER['HTTP_HOST'];\\
} else {\\
  \$CFG->wwwroot   = 'http:\/\/' . \$_SERVER['HTTP_HOST'];\\
}"
sudo sed -Ei 's/(\$CFG->wwwroot)\s*=.*/'"${conf_to_replace}"'/g' /mountdir/moodle/config.php


#install git tools
sudo apt-get -y install git-all    

#get the bitnami Docker image
sudo mkdir -p /moodle-image
sudo chmod 777 /moodle-image
git clone https://github.com/vjcruz007/azure-moodle-aks.git /moodle-image/      #get from modified repo with args

#get Docker tools
#get Docker repository
apt-mark showinstall | grep -q "^$docker" && sudo apt-get -y remove docker
apt-mark showinstall | grep -q "^$docker-engine" && sudo apt-get -y remove docker-engine
apt-mark showinstall | grep -q "^$docker.io" && sudo apt-get -y remove docker.io
apt-mark showinstall | grep -q "^$containerd" && sudo apt-get -y remove containerd
apt-mark showinstall | grep -q "^$runc" && sudo apt-get -y remove runc

sudo apt-get -y update
sudo apt-get -y install apt-transport-https ca-certificates curl gnupg lsb-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

#get Docker engine
sudo apt-get -y update
sudo apt-get -y install docker-ce docker-ce-cli containerd.io

#set php version and php, libphp checksum variables
if [[ "$phpVersion" == "7.4" ]]
    then
    phpV="7.4.20"
    phpCS=35fb8a14f2f1b2d6f1b5ee01b0c60663522effe870a5c97c8a298450b68083e7
    libphpCS=1af7c0e363486d06c5df6476c04c859dc816d6d4c6fd87bb3065cb15cd71968c
elif [[ "$phpVersion" == "7.3" ]]
    then
    phpV="7.3.28"
    phpCS=029ca7c2678b4ccfb07db3b4ad18724070e0f49528ad17b42bbcf6b20620e574
    libphpCS=70777f4c71ed24d033410bb3eaf4475d12aec111b971d7a3ed3f6935db72ed51
elif [[ "$phpVersion" == "7.2" ]]
    then
    phpV="7.2.34"
    phpCS=8ebf19d1e14e07fb330b4e955ebcc15bfd513d3f7bd336f6a8ecf319b152f717
    libphpCS=93bdc05dcbd4069b200999613931c206d480ab234c35fb6052be23f3801d3b0
else
    echo "Only php versions 7.2, 7.3 and 7.4 are supported presently"
    exit
fi

#set apache version and checksum
apacheVersion="2.4.41"
apacheCS=0364e80e08a89fda2d2d302609f813d5d497b6cb6bcf6643d2770b825abbc0fb

#Build the container image
sudo docker build --build-arg PHP_VERSION=$phpV --build-arg APACHE_VERSION=$apacheVersion --build-arg LIBPHP_VERSION=$phpV --build-arg LIBPHP_CS=$libphpCS --build-arg PHP_CS=$phpCS --build-arg APACHE_CS=$apacheCS -t moodle-image /moodle-image/moodle-image/

#Publish to ACR
sudo docker tag moodle-image $ACRname.azurecr.io/moodle-image:v1 

#authenticate ACR using ACR token(admin enable and get token while ACR is created in ARM template)
sudo docker login $ACRname.azurecr.io --username $ACRusername --password $ACRtoken

#push to ACR
sudo docker push $ACRname.azurecr.io/moodle-image:v1

#creating kubernetes secret
kubectl create secret docker-registry acr-secret --docker-server $ACRname.azurecr.io --docker-username $ACRname --docker-password $ACRtoken

#add bitnami chart repo to helm
helm repo add bitnami https://charts.bitnami.com/bitnami

#helm install if useAzureDisk is set to true, then pvc of disk is given in existing claim else pvc of azure file is given
if [ "$useAzureDisk" = "true" ]; then
    helm install moodle bitnami/moodle -f https://raw.githubusercontent.com/neerajajaja/moodle-to-azure-aks/master/moodle-arm-templates/aks/values.yaml --set image.registry=$ACRname.azurecr.io --set image.pullSecrets[0]=acr-secret --set image.repository=moodle-image --set image.tag=v1 --set moodleSkipInstall=true --set mariadb.enabled=false --set extraEnvVars[0].name=MOODLE_DATABASE_TYPE --set extraEnvVars[0].value=mysqli --set persistence.enabled=true --set persistence.existingClaim=azure-managed-disk --set externalDatabase.host=$SQLServerName --set externalDatabase.port=3306 --set externalDatabase.database=$SQLDBName  --set externalDatabase.user=$SQLServerAdmin --set externalDatabase.password=$SQLAdminPassword --set containerSecurityContext.runAsUser=0
else
    helm install moodle bitnami/moodle --set image.registry=$ACRname.azurecr.io --set image.pullSecrets[0]=acr-secret --set image.repository=moodle-image --set image.tag=v1 --set moodleSkipInstall=true --set mariadb.enabled=false --set extraEnvVars[0].name=MOODLE_DATABASE_TYPE --set extraEnvVars[0].value=mysqli --set persistence.enabled=true --set persistence.existingClaim=azurefile --set externalDatabase.host=$SQLServerName --set externalDatabase.port=3306 --set externalDatabase.database=$SQLDBName  --set externalDatabase.user=$SQLServerAdmin --set externalDatabase.password=$SQLAdminPassword --set containerSecurityContext.runAsUser=0
fi
