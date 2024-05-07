export EKS_TEST_CLUSTER=$(jq -r ".EKS_TEST_CLUSTER" values_for_script.json)
export EKS_PROD_CLUSTER=$(jq -r ".EKS_PROD_CLUSTER" values_for_script.json)
export EKS_Role_arn_to_be_added=$(jq -r ".EKS_Role_arn_to_be_added" values_for_script.json)
export CFN_STACK_NAME=$(jq -r ".CFN_STACK_NAME" values_for_script.json)
export USER_EMAIL=$(jq -r ".USER_EMAIL" values_for_script.json)
export ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "-------------------------------------------------------------------------"
echo "EKS TEST CLUSTER=$EKS_TEST_CLUSTER"
echo "EKS PROD CLUSTER=$EKS_PROD_CLUSTER"
echo "Role to add to EKS Clusters=$EKS_Role_arn_to_be_added"
echo "CloudFormation Stack Name=$CFN_STACK_NAME"
echo "EMAIL=$USER_EMAIL"
echo "-------------------------------------------------------------------------"

# echo "-------------------------------------------------------------------------"
echo "installing kubectl,eksctl,helm"
# #------------------------------------------------------------------------------------------------------------------------------------------------------------
#Install and configure kubectl
curl --silent --location -o /usr/local/bin/kubectl https://s3.us-west-2.amazonaws.com/amazon-eks/1.22.6/2022-03-09/bin/linux/amd64/kubectl
chmod +x /usr/local/bin/kubectl
kubectl version --short --client
echo kubectl done

# Install eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
mv /tmp/eksctl /usr/local/bin
eksctl version
echo eksctl done

# Install helm
curl --silent -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
helm version
echo helm done
# #------------------------------------------------------------------------------------------------------------------------------------------------------------
# echo "-------------------------------------------------------------------------"
echo "-------------------------------------------------------------------------"
echo "Creating Test Cluster"
export AWS_REGION_TEST=$(jq -r ".AWS_REGION_TEST" values_for_script.json)
envsubst < eksctlConfigFiles/Test-Cluster.yaml > eksctlConfigFiles/Placeholder.yaml
cat eksctlConfigFiles/Placeholder.yaml
eksctl create cluster -f eksctlConfigFiles/Placeholder.yaml
echo "-------------------------------------------------------------------------"
echo "-------------------------------------------------------------------------"
echo "Creating Prod Cluster"
export AWS_REGION_PROD=$(jq -r ".AWS_REGION_PROD" values_for_script.json)
envsubst < eksctlConfigFiles/Prod-Cluster.yaml > eksctlConfigFiles/Placeholder.yaml
cat eksctlConfigFiles/Placeholder.yaml
#Creating Prod Cluster
eksctl create cluster -f eksctlConfigFiles/Placeholder.yaml
echo "-------------------------------------------------------------------------"
# ------------------------------------------------------------------------------------------------------------------------------------------------------------
echo "-------------------------------------------------------------------------"
echo "Processing test cluster"
aws eks update-kubeconfig --region $AWS_REGION_TEST --name $EKS_TEST_CLUSTER
#adding EKS_Role_arn_to_be_added to aws-auth configmap
eksctl utils associate-iam-oidc-provider --region $AWS_REGION_TEST --cluster $EKS_TEST_CLUSTER --approve
eksctl create iamidentitymapping --region $AWS_REGION_TEST --cluster $EKS_TEST_CLUSTER --arn $EKS_Role_arn_to_be_added --username k8sadmin --group system:masters
echo "-------------------------------------------------------------------------"
#------------------------------------------------------------------------------------------------------------------------------------------------------------
echo "-------------------------------------------------------------------------"
echo "Processing Prod cluster"
aws eks update-kubeconfig --region $AWS_REGION_PROD --name $EKS_PROD_CLUSTER
#adding EKS_Role_arn_to_be_added to aws-auth configmap
eksctl utils associate-iam-oidc-provider --region $AWS_REGION_PROD --cluster $EKS_PROD_CLUSTER --approve
eksctl create iamidentitymapping --region $AWS_REGION_PROD --cluster $EKS_PROD_CLUSTER --arn $EKS_Role_arn_to_be_added --username k8sadmin --group system:masters
# ------------------------------------------------------------------------------------------------------------------------------------------------------------
echo "-------------------------------------------------------------------------"
echo "TEST CLUSTER OIDC ARN for ROLE"
oidc_id=$(aws eks describe-cluster --region $AWS_REGION_TEST --name $EKS_TEST_CLUSTER --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)
REGION_CODE=$(aws eks describe-cluster --region $AWS_REGION_TEST --name $EKS_TEST_CLUSTER --query "cluster.identity.oidc.issuer" --output text | cut -d '.' -f 3)
export TEST_OIDC_ARN=(arn:aws:iam::$ACCOUNT_ID:oidc-provider/oidc.eks.$REGION_CODE.amazonaws.com/id/$oidc_id)
echo $TEST_OIDC_ARN
echo "-------------------------------------------------------------------------"
echo "PROD CLUSTER OIDC ARN for ROLE"
oidc_id=$(aws eks describe-cluster --region $AWS_REGION_PROD --name $EKS_PROD_CLUSTER --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)
region_code=$(aws eks describe-cluster --region $AWS_REGION_PROD --name $EKS_PROD_CLUSTER --query "cluster.identity.oidc.issuer" --output text | cut -d '.' -f 3)
export PROD_OIDC_ARN=(arn:aws:iam::$ACCOUNT_ID:oidc-provider/oidc.eks.$region_code.amazonaws.com/id/$oidc_id)
echo $PROD_OIDC_ARN
echo "-------------------------------------------------------------------------"
#Deploy CFN stack to create:
  #ECR
  #Pipeline
echo "-------------------------------------------------------------------------"
export S3_BUCKET_TEMP="temp-${ACCOUNT_ID}-${AWS_REGION_TEST}-delete"
aws s3 mb s3://${S3_BUCKET_TEMP} --region $AWS_REGION_TEST
# aws s3 rb s3://$S3_BUCKET_TEMP --force
echo "-------------------------------------------------------------------------"
echo "CFN DEPLOY"
aws cloudformation deploy --template-file pipeline.template.yaml --region $AWS_REGION_TEST --stack-name $CFN_STACK_NAME --s3-bucket $S3_BUCKET_TEMP --parameter-overrides CodeCommitRepositoryName=applicationCodeRepo ECRRepositoryName=appcontimagerepo ProdRegion=$AWS_REGION_PROD ProdEKSClusterName=$EKS_PROD_CLUSTER RoleARNForProdEKSCluster=$EKS_Role_arn_to_be_added RoleARNForTestEKSCluster=$EKS_Role_arn_to_be_added TestEKSClusterName=$EKS_TEST_CLUSTER EMAIL=$USER_EMAIL --capabilities CAPABILITY_NAMED_IAM

wait_stack_create() {
    STACK_NAME=$CFN_STACK_NAME
    echo "Waiting for [$STACK_NAME] stack creation."
    aws cloudformation wait stack-create-complete \
    --region ${REGION}  \
    --stack-name ${STACK_NAME}
    status=$?

    if [[ ${status} -ne 0 ]] ; then
        # Waiter encountered a failure state.
        echo "Stack [${STACK_NAME}] creation failed. AWS error code is ${status}."

        exit ${status}
    fi
}
echo "-------------------------------------------------------------------------"
export CODE_COMMIT=$(aws cloudformation describe-stacks --region $AWS_REGION_TEST --stack-name $CFN_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='CodeCommitRepoCloneURLHTTPS'].OutputValue" --output text)
echo $CODE_COMMIT
echo "-------------------------------------------------------------------------"
export ALB_ROLE_TEST_ARN=$(aws cloudformation describe-stacks --region $AWS_REGION_TEST --stack-name $CFN_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='TESTROLEALB'].OutputValue" --output text)
ALB_ROLE_TEST=$(echo $ALB_ROLE_TEST_ARN | cut -d '/' -f 2)
echo $ALB_ROLE_TEST
export ALB_ROLE_PROD_ARN=$(aws cloudformation describe-stacks --region $AWS_REGION_TEST --stack-name $CFN_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='PRODROLEALB'].OutputValue" --output text)
ALB_ROLE_PROD=$(echo $ALB_ROLE_PROD_ARN | cut -d '/' -f 2)
echo $ALB_ROLE_PROD
echo "-------------------------------------------------------------------------"
export OIDC_ARN=$TEST_OIDC_ARN
envsubst < policyDoc.json > trust.json
aws iam update-assume-role-policy --role-name $ALB_ROLE_TEST --policy-document file://trust.json

export OIDC_ARN=$PROD_OIDC_ARN
envsubst < policyDoc.json > trust.json
aws iam update-assume-role-policy --role-name $ALB_ROLE_PROD --policy-document file://trust.json

echo "-------------------------------------------------------------------------"
cd Application/
echo "-------------------------------------------------------------------------"
echo "install ALB CONTROLLER"
helm upgrade --install loadbalancer -n kube-system aws-load-balancer-controller \
  --set clusterName=$EKS_TEST_CLUSTER \
  --set serviceAccount.create=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$ALB_ROLE_TEST_ARN \
  --set serviceAccount.name=aws-load-balancer-controller
echo "-------------------------------------------------------------------------"
echo "prod"
echo "-------------------------------------------------------------------------"
helm upgrade --install loadbalancer -n kube-system aws-load-balancer-controller \
    --set clusterName=$EKS_PROD_CLUSTER \
    --set serviceAccount.create=true \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$ALB_ROLE_PROD_ARN \
    --set serviceAccount.name=aws-load-balancer-controller
echo "-------------------------------------------------------------------------"
echo "final"
git init
git remote add origin $CODE_COMMIT
git add .
git commit -m "Initial commit"
git branch -M main
git push -u origin main
aws s3 rb s3://$S3_BUCKET_TEMP --force
echo "complete"
echo "-------------------------------------------------------------------------"
