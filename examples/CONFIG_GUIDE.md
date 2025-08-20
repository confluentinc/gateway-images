# Configuring Gateway

- [1. Top-Level Layout](#1-top-level-layout)
- [2. Streaming Domains](#2-streaming-domains)
- [3. Routes](#3-routes)
- [4. Admin and Metrics](#4-admin-and-metrics)
- [5. Secret Stores](#5-secret-stores)

## 1. Top-Level Layout

```yaml
gateway:
  name: string                    # Gateway instance identifier
  streamingDomains: []            # Target Kafka clusters
  secretStores: []                # Credential stores (optional, required for auth swap)
  routes: []                      # Client routing rules
  admin: {}                       # Admin and metrics configuration
  advanced: {}                    # Advanced settings (optional)
```

## 2. Streaming Domains

```yaml
streamingDomains:
  - name: sales # unique across gateway
    type: kafka # default: kafka
    kafkaCluster:
      name: sales-cluster # default: <streamingDomain.name>
      bootstrapServers:
        - id: PLAINTEXT-1
          endpoint: PLAINTEXT://kafka0.example.com:9092
        - id: SASL_SSL-1
          endpoint: SASL_SSL://kafka0.example.com:9093
          ssl:  # required when using SASL_SSL/SSL
            ignoreTrust: false
            truststore:
              type: PKCS12  # default: JKS
              location: /opt/ssl/client-truststore.p12
              password:
                file: /opt/secrets/client-truststore.password
            keystore: # gateway’s identity when needed
              type: PKCS12 # default: JKS
              location: /opt/ssl/gw-keystore.p12
              password:
                file: /opt/secrets/gw-keystore.password
              keyPassword:
                value: inline-password
      nodeIdRanges:             # required if any route uses brokerIdentificationStrategy.type=port
        - name: default
          start: 0              # inclusive
          end: 3                # inclusive
```

#### Notes
- `password` can be a file path or an inline value.
- `ignoreTrust` is used to skip certificate validation (not recommended for production). Other settings will be ignored if `ignoreTrust` is true.

## 3. Routes

```yaml
routes:
  - name: eu-sales               # unique across routes
    endpoint: eu-gw.sales.example.com:9092  # what clients connect to

    brokerIdentificationStrategy:
      # How clients discover individual brokers
      type: port | host
      # when type=host
      pattern: broker-$(nodeId).eu-gw.sales.example.com:9092

    streamingDomain:
      name: sales               # must reference gateway.streamingDomains[].name
      bootstrapServerId: SASL_SSL-1 # must match kafkaCluster.bootstrapServers[].id
    security:
      auth: passthrough | swap
      ssl:                      # gateway side TLS/mTLS
        ignoreTrust: false
        truststore:
          type: PKCS12
          location: /opt/ssl/client-truststore.p12
          password:
            file: /opt/secrets/client-truststore.password
        keystore:
          type: PKCS12
          location: /opt/ssl/gw-keystore.p12
          password:
            file: /opt/secrets/gw-keystore.password
          keyPassword:
            value: inline-password
        clientAuth: required    # required|requested|none

      # Only when auth=swap (examples below)
      swapConfig:
        clientAuth:             # how clients auth to the gateway
          sasl:
            mechanism: PLAIN    # PLAIN | OAUTHBEARER | ...
            callbackHandlerClass: "org.apache.kafka.common.security.plain.PlainServerCallbackHandler"
            jaasConfig:
              file: /opt/gateway/gw-users.conf
            connectionsMaxReauthMs: 0
        # required: where to fetch credentials/secrets for swap
        secretStore: kms1
        # how gateway authenticates to the cluster after swapping
        clusterAuth:
          sasl:
            mechanism: OAUTHBEARER
            jaasConfig:
              file: /opt/gateway/cluster-login.tmpl.conf
            oauth:
              tokenEndpointUri: https://idp.company.com/realms/cp/protocol/openid-connect/token
```

#### Notes
- `port` strategy requires matching nodeIdRanges on the referenced kafkaCluster.
- `host` strategy requires pattern with `$(nodeId)` placeholder.
- supported certificate types: `JKS`, `PKCS12` & `PEM`

## 4. Admin and Metrics

```yaml
admin:
  bindAddress: 0.0.0.0   # default
  port: 9190             # default
  endpoints:
    metrics: true
  jvmMetrics:            # jvmMetrics enabled by default. Use any micrometer supported metrics.
    - JvmGcMetrics
    - JvmMemoryMetrics
    - JvmThreadMetrics
    - ProcessorMetrics
    - UptimeMetrics
  commonTags:            # optional
    host: pod-0
    region: us-west-2
```

## 5. Secret Stores

### Hashicorp Vault

#### Connect using Auth Token
```yaml
secretStores:
  - name: kms1
    provider:
      type: VAULT
      config:
        address: https://vault.prod.company.com
        authToken: <auth-token>
        path: /secrets/prod/gateway/swap-creds
        prefixPath: ""               # optional
        separator: ":"           # optional
```

#### Connect using AppRole
```yaml
  - name: kms1
    provider:
      type: VAULT
      config:
        address: https://vault.prod.company.com
        authMethod: AppRole
        role: xxxx-xx-xxxx-xxxx-xxxx
        secret: xxxx-xx-xxxx-xxxx-xxxx
        path: /secrets/prod/gateway/swap-creds
        prefixPath: ""          # optional
        separator: ":"           # optional
```

#### Connect using Username/Password
```yaml
  - name: kms1
    provider:
      type: VAULT
      config:
        address: https://vault.prod.company.com
        authMethod: UserPass
        username: <username>
        password: <password>
        path: /secrets/prod/gateway/swap-creds
        prefixPath: ""          # optional
        separator: ":"          # optional
```

#### Connect using Certificates

__Not Supported__

### AWS Secrets Manager

#### Connect using IAM Role
```yaml
  - name: aws-secrets
    provider:
      type: AWS
      config:
        region: us-west-2
        endpointOverride: https://secretsmanager.us-west-2.amazonaws.com # optional, defaults to AWS region endpoint
        prefixPath: confluent- # optional, defaults to empty
        separator: ":" # optional, defaults to ":"
        useJson: true # if true, expects secrets in JSON format
```

#### Connect using Access Key and Secret Key
```yaml
  - name: aws-secrets
    provider:
      type: AWS
      config:
        region: us-west-2
        accessKey: <access-key> # optional if using IAM role
        secretKey: <secret-key> # optional if using IAM role
        endpointOverride: https://secretsmanager.us-west-2.amazonaws.com # optional, defaults to AWS region endpoint
        prefixPath: "" # optional, defaults to empty
        separator: ":" # optional, defaults to ":"
        useJson: true # if true, expects secrets in JSON format
```

### Azure Key Vault

#### Connect using Client ID and Secret

```yaml
  - name: azure-keyvault
    provider:
      type: AZURE
      config:
        vaultUrl: https://authswap.vault.azure.net/
        credentialType: ClientSecret
        tenantId: xxxx-xxxx-xxxx-xxxx-xxxxxxxx
        clientId: xxxx-xxxx-xxxx-xxxx-xxxxxxxx
        clientSecret: <client-secret>
        prefixPath: "" # optional, defaults to empty
        separator: ":"
```

#### Connect using Username and Password

```yaml
  - name: azure-keyvault
    provider:
      type: AZURE
      config:
        vaultUrl: https://authswap.vault.azure.net/
        credentialType: UsernamePassword
        tenantId: xxxx-xxxx-xxxx-xxxx-xxxxxxxx
        clientId: xxxx-xxxx-xxxx-xxxx-xxxxxxxx
        username: <username>
        password: <password>
        prefixPath: "" # optional, defaults to empty
        separator: ":" # optional, defaults to ":"
```

#### Connect using Client Certificate

##### PEM certificate

```yaml
  - name: azure-keyvault
    provider:
      type: AZURE
      config:
        vaultUrl: https://authswap.vault.azure.net/
        credentialType: ClientCertificate
        tenantId: xxxx-xxxx-xxxx-xxxx-xxxxxxxx
        clientId: xxxx-xxxx-xxxx-xxxx-xxxxxxxx
        certificatePath: /opt/ssl/client-cert.pem
        prefixPath: "" # optional, defaults to empty
        separator: ":" # optional, defaults to ":"
```

##### PFX certificate

```yaml
  - name: azure-keyvault
    provider:
      type: AZURE
      config:
        vaultUrl: https://authswap.vault.azure.net/
        credentialType: ClientCertificate
        tenantId: 0893715b-959b-4906-a185-2789e1ead045
        clientId: 1b4e0478-8dfb-47eb-9e63-dd8c2ce10384
        certificateType: PFX
        certificatePath: /opt/ssl/client-cert.pfx
        certificatePfxPassword: <pfx-password>
        prefixPath: "" # optional, defaults to empty
        separator: ":" # optional, defaults to ":"
```
