# Challenge

k3d cluster with Strimzi, CloudNativePG and the sre-challenge apps, launched by one script.

- [Challenge](#challenge)
  - [Hello](#hello)
  - [Improvements](#improvements)
  - [Required](#required)
  - [Run](#run)
  - [Run without the script](#run-without-the-script)


## Hello

Hey there. Some reasoning to explain what I've done here and why. 

The app itself is a toy pipeline that passes a message from one end to the other.

- front: a web API. You send it a message, and it drops the message into Kafka.
- back: listens on Kafka, takes each message, and saves it into Postgres.
- reader: a web API that lists what's been saved in Postgres.

There's also silly math being done to generate CPU activity.

I've picked k3d to host, because that's what I'm used to: It does the job. It's a plain cluster without any hardening.

For Kafka and Postgres I've chosen Strimzi and CloudNativePG. These are operators that I'm familiar with and allow me to provision both the Kafka clusters and the database through some pretty easy abstractions. 
Their Helm charts are stored under ./helm, unaltered.

I'm deploying the app via a barebones Helm chart that does what's needed: A Deployment for frontend and backend, associated Services, plus the relevant CRs to interact with the operators.

There's also a tiny chart to provision the Kafka cluster itself, again using the Strimzi custom resources.

There's some required tooling, all described below. I've also provided a script to launch it. If you'd prefer to avoid the script, there's a manuak guide too. 

Full disclosure, the script was produced with heavy AI assistance as a simple convenience thing: I generally don't like lengthy shell scrips and prefer not to write them, and I am heavily against basing essential infra upon them. Ansible or some such equivalent (or even a Python or Go script) would be my preference.

## Improvements

As I've said, this is barebones. Plenty could be done to make it more fun.

E.g., basic hardening like:

- Least-privilege RBAC: give each team and service account only the permissions it needs, and turn off anonymous API access.
- Pod Security Admission at restricted: pods run as non-root, with a read-only root filesystem, all Linux capabilities dropped + no privileged mode.
- Default-deny NetworkPolicies: block all pod traffic, then allow only the paths the app needs.

Audit logging too.

Would also be fun to host an Argo instance inside the cluster and have it handle the actual provisioning and enforcement of state. I'd have an Argo app for Strimzi, an Argo app for CloudNativePG, and, depending on organizational structure, an app or two apps for frontend and backend.

By organizational structure I mean that if it's the same team with an extended responsibility, they might find having a single app easier. If it's multiple teams, I'd split it.

The script is throwaway and definitely not something I'd use for anything other than this example.

The images for the sre-challenge app are kind of huge but I didn't want to mess with the provided tools; normally I'd have a multi-stage build with the initial setup and then a slim image to run from that contains only the essentials.

## Required

| Tool | Version |
|------|---------|
| Docker | >= 24 |
| k3d | >= 5.6 |
| kubectl | >= 1.34 |
| helm | >= 3.14 |
| JDK | 21 to 24 |
| git, curl | any |

## Run

```sh
git clone https://github.com/kaktooss/sre-challenge sre-challenge
export JAVA_HOME=/path/to/jdk-21
./launch.sh demo 5111
```

Arguments: cluster name, registry host port. Both are prompted for if omitted.

Teardown: `k3d cluster delete demo`

## Run without the script

Same thing, by hand. Cluster `demo`, registry port `5111`. Change both if you want.

Build the jars and images. Docker build context is the `libs` dir, the Dockerfiles expect the jar there.

```sh
(cd sre-challenge && ./gradlew clean build)
for a in front back reader; do
  docker build -f sre-challenge/app/$a/src/main/docker/Dockerfile \
    -t localhost:5111/sre-challenge/$a:0.1.0 sre-challenge/app/$a/build/libs
done
```

Cluster with a registry. Push the images into it.

```sh
k3d cluster create demo --servers 1 --agents 1 --registry-create demo-registry:0.0.0.0:5111
for a in front back reader; do docker push localhost:5111/sre-challenge/$a:0.1.0; done
```

Operators. Chart defaults, no overrides.

```sh
kubectl --context k3d-demo create namespace kafka
kubectl --context k3d-demo create namespace postgres
helm --kube-context k3d-demo install strimzi ./helm/strimzi-kafka-operator -n kafka --wait
helm --kube-context k3d-demo install cnpg ./helm/cloudnative-pg -n postgres --wait
```

Kafka. One broker. Takes about a minute. Helm 4 `--wait` blocks until the Kafka resource is Ready. Helm 3 `--wait` ignores custom resources, so wait with kubectl to be safe on both.

```sh
helm --kube-context k3d-demo install kafka ./helm/kafka-cluster -n kafka
kubectl --context k3d-demo -n kafka wait kafka/kafka --for=condition=Ready --timeout=300s
```

The app. Topic and PostgreSQL cluster come with it. The registry hostname inside the cluster is `<cluster>-registry:<port>`.

```sh
helm --kube-context k3d-demo install sre-challenge ./helm/sre-challenge -n sre-challenge \
  --create-namespace --set image.registry=demo-registry:5111 --wait --timeout 10m
kubectl --context k3d-demo -n sre-challenge get pods
```

To know it works: Post through front, read through reader.

```sh
kubectl --context k3d-demo -n sre-challenge port-forward svc/sre-challenge-front 18080:8080 &
kubectl --context k3d-demo -n sre-challenge port-forward svc/sre-challenge-reader 18084:8084 &
curl -X POST localhost:18080/api/v1/command -H 'Content-Type: application/json' -d '{"message":"hello"}'
curl localhost:18084/api/v1/testEntity
```

Expect a row with `hello`. Kill the port-forwards when done.

Hurray.
