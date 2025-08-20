# Gateway Configuration Guide

## Table of Contents

- [1. Top-Level Layout](#1-top-level-layout)
- [2. Streaming Domains](#2-streaming-domains)
- [3. Routes](#3-routes)
- [4. Admin and Metrics](#4-admin-and-metrics)
- [5. Secret Stores](#5-secret-stores)
- [6. SSL Configuration](#6-ssl-configuration)
- [7. Password Configuration](#7-password-configuration)

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

### 2.1 StreamingDomain

```yaml
name: string
type: kafka # default: kafka
kafkaCluster: {}
```

### 2.2 StreamingDomain.KafkaCluster

```yaml
name: string
bootstrapServers: []             # List of Kafka brokers
nodeIdRanges: []                 # Optional, required for port-based broker identification
```

### 2.3 StreamingDomain.KafkaCluster.BootstrapServer

```yaml
id: string                      # Unique identifier for the server
endpoint: string                # Host:port of the Kafka broker
ssl: {}                         # Optional, required for SSL/SASL_SSL
```

### 2.4 StreamingDomain.KafkaCluster.BootstrapServer.Ssl

See [SSL Configuration](#6-ssl-configuration) section for details.

### Full Example

```yaml
streamingDomains:
  - name: sales # unique across gateway
    type: kafka # default: kafka
    kafkaCluster:
      name: sales-cluster # default: <streamingDomain.name>
      bootstrapServers:
        - id: PLAINTEXT-1
          endpoint: kafka0.example.com:9092
        - id: SASL_SSL-1
          endpoint: kafka0.example.com:9093
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

### Notes

- `password` can be a file path or an inline value
- `ignoreTrust` is used to skip certificate validation (not recommended for production). Other settings will be ignored if `ignoreTrust` is true

## 3. Routes

### 3.1 Route

```yaml
name: string                   # Unique name for the route
endpoint: string               # Client connection endpoint (host:port)
brokerIdentificationStrategy:  # How clients discover individual brokers
  type: port | host            # port: uses nodeIdRanges, host: uses pattern
  pattern: string              # Required if type=host, e.g., broker-$(nodeId).eu-gw.sales.example.com:9092
streamingDomain:               # Reference to a streaming domain
  name: string                 # Must match gateway.streamingDomains[].name
  bootstrapServerId: string    # Must match kafkaCluster.bootstrapServers[].id
security: {}
```

### 3.2 Route.Security

```yaml
auth: passthrough | swap         # passthrough: clients connect directly to brokers, swap: auth swap
ssl: {}
swapConfig: {}                   # Required if auth=swap
```

### 3.3 Route.Security.Ssl

See [SSL Configuration](#6-ssl-configuration) section for details.

### 3.4 Route.Security.SwapConfig

_applicable only if `auth: swap`_

```yaml
clientAuth: {}               # How clients authenticate to the gateway
secretStore: string         # reference to a secret store for credentials
clusterAuth: {}             # How the gateway authenticates to the Kafka cluster after swapping
```

### 3.4.1 Route.Security.SwapConfig.ClientAuth

#### SASL Authentication
```yaml
sasl:
    mechanism: string          # e.g., PLAIN, OAUTHBEARER
    callbackHandlerClass: string # e.g., org.apache.kafka.common.security.plain.PlainServerCallbackHandler
    jaasConfig: {}             # JAAS configuration for the client
    connectionsMaxReauthMs: int # Maximum re-authentication time in milliseconds
```

##### jaasConfig
```yaml
file: string                  # Path to the JAAS configuration file
```
**content:**
```properties
KafkaServer {
    org.apache.kafka.common.security.plain.PlainLoginModule required
    username="<username>"
    password="<password>"
    user_<username>="<password>";
};
```

#### MTLS Authentication

_note: feature is not present in early access_

```yaml
mtls:
  ssl:
    principalMappingRules: [] # Optional, rules for matching client certificates
```

### 3.4.2 Route.Security.SwapConfig.ClusterAuth

#### SASL Authentication
```yaml
sasl:
    mechanism: string          # e.g., OAUTHBEARER
    jaasConfig: {}             # JAAS configuration for the cluster
    oauth: {}                  # OAuth specific configurations
```

##### jaasConfig
```yaml
file: string                  # Path to the JAAS configuration file
```

**content:**

###### plain template
```properties
org.apache.kafka.common.security.plain.PlainLoginModule required username="%s" password="%s";
```

###### oauth template
```properties
org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId="%s" clientSecret="%s";
```

##### oauth
```yaml
tokenEndpointUri: string      # URI for the OAuth token endpoint
```

### Full Example

```yaml
routes:
  - name: eu-sales                          # unique across routes
    endpoint: eu-gw.sales.example.com:9092  # what clients connect to

    brokerIdentificationStrategy:
      # How clients discover individual brokers
      type: port | host
      # when type=host
      pattern: broker-$(nodeId).eu-gw.sales.example.com:9092

    streamingDomain:
      name: sales                             # must reference gateway.streamingDomains[].name
      bootstrapServerId: SASL_SSL-1           # must match kafkaCluster.bootstrapServers[].id
    security:
      auth: passthrough | swap
      ssl:                                    # gateway side TLS/mTLS
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
        clientAuth: required                  # required|requested|none

      # Only when auth=swap (examples below)
      swapConfig:
        clientAuth:                           # how clients auth to the gateway
          sasl:
            mechanism: PLAIN                  # PLAIN | OAUTHBEARER | ...
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

### 3.6 Notes

- `port` strategy requires matching nodeIdRanges on the referenced kafkaCluster
- `host` strategy requires pattern with `$(nodeId)` placeholder
- Supported certificate types: `JKS`, `PKCS12` & `PEM`

## 4. Admin and Metrics

```yaml
admin:
  bindAddress: 0.0.0.0                 # default
  port: 9190                           # default
  endpoints:
    metrics: true
  jvmMetrics:                          # jvmMetrics enabled by default. Use any micrometer supported metrics.
    - JvmGcMetrics
    - JvmMemoryMetrics
    - JvmThreadMetrics
    - ProcessorMetrics
    - UptimeMetrics
  commonTags:                          # optional
    host: pod-0
    region: us-west-2
```

## 5. Secret Stores

### 5.1 HashiCorp Vault

#### 5.1.1 Connect using Auth Token
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

#### 5.1.2 Connect using AppRole
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

#### 5.1.3 Connect using Username/Password
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

#### 5.1.4 Connect using Certificates

_Not Supported_

### 5.2 AWS Secrets Manager

#### 5.2.1 Connect using IAM Role
```yaml
  - name: aws-secrets
    provider:
      type: AWS
      config:
        region: us-west-2
        endpointOverride: https://secretsmanager.us-west-2.amazonaws.com  # optional, defaults to AWS region endpoint
        prefixPath: confluent-           # optional, defaults to empty
        separator: ":"                   # optional, defaults to ":"
        useJson: true                    # if true, expects secrets in JSON format
```

#### 5.2.2 Connect using Access Key and Secret Key
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

### 5.3 Azure Key Vault

#### 5.3.1 Connect using Client ID and Secret

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

#### 5.3.2 Connect using Username and Password

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

#### 5.3.3 Connect using Client Certificate

##### 5.3.3.1 PEM certificate

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

##### 5.3.3.2 PFX certificate

```yaml
  - name: azure-keyvault
    provider:
      type: AZURE
      config:
        vaultUrl: https://authswap.vault.azure.net/
        credentialType: ClientCertificate
        tenantId: xxxx-xxxx-xxxx-xxxx-xxxxxxxx
        clientId: xxxx-xxxx-xxxx-xxxx-xxxxxxxx
        certificateType: PFX
        certificatePath: /opt/ssl/client-cert.pfx
        certificatePfxPassword: <pfx-password>
        prefixPath: "" # optional, defaults to empty
        separator: ":" # optional, defaults to ":"
```

## 6. SSL Configuration

### 6.1 SSL Configuration

```yaml
ignoreTrust: boolean            # Skip certificate validation (not recommended for production)
truststore: {}                  # Truststore configuration
keystore: {}                    # Keystore configuration (gateway identity)
```

### 6.2 Truststore and Keystore

```yaml
type: string                    # Certificate type (JKS, PKCS12, PEM)
location: string                # Path to the truststore/keystore file
password: {}                    # Password for the truststore/keystore
```

## 7. Password Configuration

### 7.1 File based
```yaml
file: string                     # Path to a file containing the password
```

### 7.2 Inline value
```yaml
value: string                    # Inline password value
```