// Local build of the stock Radius Kubernetes container Recipe (radius-project/resource-types-contrib,
// Compute/containers). Changes from it are marked LOCAL ADDITION, and its Dapr sidecar support is
// removed: no application in this library uses Dapr. The upstream Recipe is licensed under the
// Apache License 2.0, which covers this file too: see kubernetes-containers.LICENSE.
@description('Radius context object passed into the recipe.')
param context object

// LOCAL ADDITION. How a workload proves its identity and pulls its images is a platform
// decision. The Recipe Pack sets these once per environment and every container gets them, so the
// application definition never mentions service accounts, pull secrets, volumes or certificates.
//
// `{resource}` in serviceAccountName, in containerEnv values and in containerEnvFromSecrets stands
// for the container resource's name, so each service gets its own identity and credentials from
// one setting. A service account name with the placeholder is created by this Recipe.
@description('Kubernetes ServiceAccount the pods run as. Empty uses the namespace default. May contain {resource}.')
param serviceAccountName string = ''

@description('Label pods for Microsoft Entra Workload ID, so its webhook injects AZURE_CLIENT_ID and the federated token.')
param azureWorkloadIdentity bool = false

@description('Client ID of each resource\'s managed identity, by resource name, for the service account this Recipe creates.')
param workloadClientIds object = {}

@description('Existing image pull secret in the application namespace, for a registry that requires authentication.')
param imagePullSecretName string = ''

@description('''
Extra pod volumes, as Kubernetes volume objects, added to every pod. The Recipe Pack uses these to
hand the platform's identity material to the application, such as a projected ServiceAccount token
or a CA certificate. The Recipe doesn't interpret them.
''')
param platformPodVolumes array = []

@description('Volume mounts, as Kubernetes volumeMount objects, added to every container. Usually mount platformPodVolumes.')
param containerVolumeMounts array = []

@description('Environment variables, as Kubernetes EnvVar objects, added to every container. Values may contain {resource}.')
param containerEnv array = []

@description('''
Kubernetes Secrets, by name, whose keys become environment variables of every container. Names may
contain {resource}, for credentials that differ per service. A missing Secret is skipped.
''')
param containerEnvFromSecrets array = []

@description('''
Kubernetes Secrets, by Resource Type, for credentials the platform issues instead of that type's
Recipe, such as keys to a shared object store. A container connected to a resource of the type gets
the Secret's keys as CONNECTION_<NAME>_<KEY> variables; other containers don't.
''')
param connectionSecretNames object = {}

@description('Pod labels, by Resource Type, for pods connected to a resource of that type, so the platform\'s network policies can let them in.')
param connectionPodLabels object = {}

@description('''
cert-manager ClusterIssuer that gives every container declaring a port named `https` a certificate
for its Service's DNS names, so callers in the cluster reach it over TLS and can verify it. The
certificate and key are mounted at /etc/service-tls, and TLS_CERT_FILE and TLS_KEY_FILE point to
them. Empty issues none.
''')
param serviceCertificateIssuer string = ''

@description('''
Pod security context of every pod. The default meets the Kubernetes "restricted" Pod Security
Standard: the image must run as a numeric non-root user. A resource can replace it through
platformOptions.podSecurityContext.
''')
param podSecurityContext object = {
  runAsNonRoot: true
  seccompProfile: { type: 'RuntimeDefault' }
}

@description('''
Security context of every container. The default meets the "restricted" Pod Security Standard. Add
readOnlyRootFilesystem where the images allow it. A resource can replace it through
platformOptions.containerSecurityContext.
''')
param containerSecurityContext object = {
  allowPrivilegeEscalation: false
  capabilities: { drop: [ 'ALL' ] }
}

extension kubernetes with {
  kubeConfig: ''
  namespace: context.runtime.kubernetes.namespace
} as kubernetes

var resourceName = context.resource.name
var namespace = context.runtime.kubernetes.namespace
var normalizedName = toLower(resourceName)

var resourceProperties = context.resource.?properties ?? {}
var containerItems = items(resourceProperties.?containers ?? {})

var environmentSegments = resourceProperties.environment != null ? split(string(resourceProperties.environment), '/') : []
var environmentLabel = length(environmentSegments) > 0 ? last(environmentSegments) : ''

// Labels
var labels = {
  'radapp.io/resource': resourceName
  'radapp.io/environment': environmentLabel
  'radapp.io/application': context.application == null ? '' : context.application.name
}

// ------------------------------------------------------------------------------------------------
// Pod identity and registry settings
//
// LOCAL ADDITION. Normally set by the Recipe Pack through the parameters above, so the application
// never declares them. A resource can still override them through `platformOptions`, which the
// Resource Type documents as "Kubernetes Deployment and Pod override properties" but the upstream
// Kubernetes Recipe does not yet read (radius-project/resource-types-contrib#143), using the flat
// key convention of the ACI Recipe:
//
//   platformOptions: {
//     serviceAccountName: 'my-service-account'
//     podLabels: { 'azure.workload.identity/use': 'true' }
//     imagePullSecrets: [ { name: 'my-registry' } ]
//     podSecurityContext: { runAsNonRoot: true, runAsUser: 1000, seccompProfile: { type: 'RuntimeDefault' } }
//     containerSecurityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ 'ALL' ] } }
//   }
//
// The service account fixes the `sub` claim of the projected token an identity provider matches
// the workload on. On Azure the pod label makes the Workload Identity webhook inject
// AZURE_CLIENT_ID, AZURE_TENANT_ID and AZURE_FEDERATED_TOKEN_FILE. On Azure Local the kubelet
// authenticates to the in-cluster connected registry with the pull secret.
// ------------------------------------------------------------------------------------------------
var platformOptions = resourceProperties.?platformOptions ?? {}
var platformPodLabels = union(
  platformOptions.?podLabels ?? {},
  azureWorkloadIdentity ? { 'azure.workload.identity/use': 'true' } : {}
)
var platformServiceAccountName = platformOptions.?serviceAccountName ?? replace(serviceAccountName, '{resource}', normalizedName)
var createServiceAccount = !contains(platformOptions, 'serviceAccountName') && contains(serviceAccountName, '{resource}')
var platformImagePullSecrets = platformOptions.?imagePullSecrets ?? (empty(imagePullSecretName) ? [] : [
  { name: imagePullSecretName }
])
// LOCAL ADDITION. Every pod and container runs without privileges unless the resource says otherwise.
var platformPodSecurityContext = platformOptions.?podSecurityContext ?? podSecurityContext
var platformContainerSecurityContext = platformOptions.?containerSecurityContext ?? containerSecurityContext

// Extra volumes, mounts and environment from the Recipe Pack, added to every pod and container.
var platformVolumes = platformPodVolumes
var platformVolumeMounts = containerVolumeMounts
var platformEnvVars = map(containerEnv, envVar => contains(envVar, 'value')
  ? union(envVar, { value: replace(string(envVar.value), '{resource}', normalizedName) })
  : envVar)
var platformEnvFrom = map(containerEnvFromSecrets, secretName => {
  secretRef: {
    name: replace(string(secretName), '{resource}', normalizedName)
    optional: true
  }
})

// LOCAL ADDITION. Service TLS: containers that declare an `https` port, and the certificate each
// gets for its Service. The Secret has the same name as the Certificate.
var serviceTlsDir = '/etc/service-tls'
var serviceTlsContainers = empty(serviceCertificateIssuer) ? [] : filter(containerItems, item => contains(item.value.?ports ?? {}, 'https'))
var serviceTlsVolumes = map(serviceTlsContainers, item => {
  name: 'service-tls-${toLower(item.key)}'
  secret: { secretName: '${normalizedName}-${toLower(item.key)}-tls' }
})
// Extract connection data from linked resources (merged with resource properties)
var resourceConnections = context.resource.?connections ?? {}
var connectionDefinitions = context.resource.properties.?connections ?? {}

// Properties to exclude from connection environment variables
var excludedProperties = ['recipe', 'secrets', 'status', 'provisioningState']
var topLevelExcludedProperties = ['recipe', 'secrets', 'status', 'provisioningState', 'properties', 'secretName']

// Identify direct Radius secret connections from resolved resource metadata.
var isSecretsResource = reduce(items(resourceConnections), {}, (acc, conn) => union(acc, {
  '${conn.key}': string(conn.value.?type ?? '') == 'Radius.Security/secrets' || (contains(connectionDefinitions, conn.key) && contains(string(connectionDefinitions[conn.key].?source ?? ''), 'Radius.Security/secrets'))
}))

// Resolved and declared connection maps can briefly differ while dependencies update.
var disableDefaultEnvVars = reduce(items(resourceConnections), {}, (acc, conn) => union(acc, {
  '${conn.key}': contains(connectionDefinitions, conn.key)
    ? connectionDefinitions[conn.key].?disableDefaultEnvVars == true
    : false
}))

// A direct Radius.Security/secrets connection injects each declared data key.
var directSecretEnvVars = reduce(items(resourceConnections), [], (acc, conn) =>
  disableDefaultEnvVars[conn.key] || !isSecretsResource[conn.key]
    ? acc
    : concat(
        acc,
        reduce(items(conn.value.?properties.?data ?? {}), [], (envAcc, secret) => concat(envAcc, [{
          name: toUpper('CONNECTION_${conn.key}_${secret.key}')
          valueFrom: {
            secretKeyRef: {
              name: last(split(string(connectionDefinitions[conn.key].source), '/'))
              key: secret.key
            }
          }
        }]))
      )
)

// Producer Recipe secrets arrive as reference metadata, separate from ordinary properties.
var managedSecretEnvVars = reduce(items(resourceConnections), [], (acc, conn) =>
  disableDefaultEnvVars[conn.key] || isSecretsResource[conn.key]
    ? acc
    : concat(
        acc,
        reduce(items(conn.value.?secrets ?? {}), [], (envAcc, secret) => concat(envAcc, [{
          name: toUpper('CONNECTION_${conn.key}_${secret.key}')
          valueFrom: {
            secretKeyRef: {
              name: last(split(string(secret.value.source), '/'))
              key: string(secret.value.key)
            }
          }
        }]))
      )
)

var secretConnectionEnvVars = concat(directSecretEnvVars, managedSecretEnvVars)
var secretConnectionEnvVarNames = map(secretConnectionEnvVars, envVar => envVar.name)
var validatedSecretConnectionEnvVars = length(secretConnectionEnvVarNames) == length(union(secretConnectionEnvVarNames, secretConnectionEnvVarNames))
  ? secretConnectionEnvVars
  : fail('Connection secret keys must produce unique environment variable names after uppercasing.')

// When a connection has a secretName property, inject all secret keys via envFrom.secretRef.
// LOCAL ADDITION: the same for credentials a producer Recipe returned in `result.secrets`, which
// Radius stores in a managed Secret named on `properties.secrets.name`. The application then
// receives them as CONNECTION_<NAME>_<KEY> without declaring each one, and a Recipe that issues no
// credentials (managed identity) simply injects none.
var secretNameEnvFrom = reduce(items(resourceConnections), [], (acc, conn) =>
  disableDefaultEnvVars[conn.key]
    ? acc
    : contains(conn.value ?? {}, 'secretName')
      ? concat(acc, [{
          prefix: toUpper('CONNECTION_${conn.key}_')
          secretRef: {
            name: string(conn.value.secretName)
          }
        }])
      : contains(conn.value.?properties ?? {}, 'secretName')
        ? concat(acc, [{
            prefix: toUpper('CONNECTION_${conn.key}_')
            secretRef: {
              name: string(conn.value.properties.secretName)
            }
          }])
        : !empty(string(conn.value.?properties.?secrets.?name ?? ''))
          ? concat(acc, [{
              prefix: toUpper('CONNECTION_${conn.key}_')
              secretRef: {
                name: string(conn.value.properties.secrets.name)
                optional: true
              }
            }])
          : acc
)

// LOCAL ADDITION. Platform credentials and pod labels for connections to the Resource Types named in
// connectionSecretNames and connectionPodLabels. The type comes from the resolved resource or, while it
// is still updating, from the declared source ID (.../providers/<namespace>/<type>/<name>).
var platformConnectionEnvFrom = reduce(items(resourceConnections), [], (acc, conn) =>
  disableDefaultEnvVars[conn.key]
    ? acc
    : concat(acc, map(
        filter(items(connectionSecretNames), typeSecret =>
          toLower(string(conn.value.?type ?? '')) == toLower(typeSecret.key) || (contains(connectionDefinitions, conn.key) && contains(toLower(string(connectionDefinitions[conn.key].?source ?? '')), toLower('/providers/${typeSecret.key}/')))),
        typeSecret => {
          prefix: toUpper('CONNECTION_${conn.key}_')
          secretRef: {
            name: string(typeSecret.value)
          }
        }))
)
var platformConnectionPodLabels = reduce(items(resourceConnections), {}, (acc, conn) =>
  union(acc, reduce(
    filter(items(connectionPodLabels), typeLabels =>
      toLower(string(conn.value.?type ?? '')) == toLower(typeLabels.key) || (contains(connectionDefinitions, conn.key) && contains(toLower(string(connectionDefinitions[conn.key].?source ?? '')), toLower('/providers/${typeLabels.key}/')))),
    {}, (labelAcc, typeLabels) => union(labelAcc, typeLabels.value)))
)

// Ordinary top-level scalar values and nested producer properties become
// CONNECTION_<CONNECTION_NAME>_<PROPERTY_NAME>.
// Null-valued properties are skipped: sensitive properties (e.g. a database
// password marked x-radius-sensitive) are redacted to null on reads, and
// string(null) fails ARM template validation with "InvalidTemplate".
var rawConnectionEnvVars = reduce(items(resourceConnections), [], (acc, conn) =>
  isSecretsResource[conn.key] || disableDefaultEnvVars[conn.key]
    ? acc
    : concat(
        acc,
        reduce(items(conn.value ?? {}), [], (envAcc, prop) =>
          (contains(topLevelExcludedProperties, prop.key) || prop.value == null)
            ? envAcc
            : concat(envAcc, [{
                name: toUpper('CONNECTION_${conn.key}_${prop.key}')
                value: string(prop.value)
              }])
        ),
        reduce(items(conn.value.?properties ?? {}), [], (envAcc, prop) =>
          (prop.key == 'secretName' || contains(excludedProperties, prop.key) || prop.value == null)
            ? envAcc
            : concat(envAcc, [{
                name: toUpper('CONNECTION_${conn.key}_${prop.key}')
                value: string(prop.value)
              }])
        )
      )
)

// Managed secret references take precedence over an ordinary output with the same name.
var connectionEnvVars = filter(rawConnectionEnvVars, envVar => !contains(secretConnectionEnvVarNames, envVar.name))

// Use replicas from properties, default to 1 if not specified
var replicaCount = resourceProperties.?replicas != null ? int(resourceProperties.replicas) : 1

// Build container specs once and partition into workload/init sets
var containerSpecs = reduce(containerItems, [], (acc, item) => concat(acc, [{
  isInit: item.value.?initContainer ?? false
  spec: union(
    {
      name: toLower(item.key)
      image: item.value.image
      securityContext: platformContainerSecurityContext
    },
    // Add ports if they exist
    contains(item.value, 'ports') ? {
      ports: reduce(items(item.value.ports), [], (portAcc, port) => concat(portAcc, [{
        name: toLower(port.key)
        containerPort: port.value.containerPort
        protocol: port.value.?protocol ?? 'TCP'
      }]))
    } : {},
    // Add environment variables from container definition and connections
    // Connection environment variables are automatically added from output values
    (contains(item.value, 'env') || length(connectionEnvVars) > 0 || length(validatedSecretConnectionEnvVars) > 0 || length(platformEnvVars) > 0 || (!empty(serviceCertificateIssuer) && contains(item.value.?ports ?? {}, 'https'))) ? {
      // Kubelet expands $(VAR) in an env var's value ONLY against env vars defined
      // earlier in this container's ordered env list. Emit secret/valueFrom env vars
      // FIRST so plain value env vars can compose them via $(VAR) without leaking
      // plaintext through Radius state. (items() sorts by key, so a single mixed list
      // would order secrets vs values by name only, which is not a real guarantee.)
      env: concat(
        // 1. Container-defined secret-backed (valueFrom.secretKeyRef) env vars.
        reduce(items(item.value.?env ?? {}), [], (envAcc, envItem) =>
          (contains(envItem.value, 'valueFrom') && contains(envItem.value.valueFrom, 'secretKeyRef'))
            ? concat(envAcc, [{
                name: envItem.key
                valueFrom: {
                  secretKeyRef: {
                    name: envItem.value.valueFrom.secretKeyRef.secretName
                    key: envItem.value.valueFrom.secretKeyRef.key
                  }
                }
              }])
            : envAcc),
        // 2. Connection secret variables, unless an explicit variable uses the same name.
        filter(validatedSecretConnectionEnvVars, envVar => !contains(item.value.?env ?? {}, envVar.name)),
        // 3. Container-defined plain value env vars (may reference the secrets above).
        reduce(items(item.value.?env ?? {}), [], (envAcc, envItem) =>
          contains(envItem.value, 'value')
            ? concat(envAcc, [{
                name: envItem.key
                value: envItem.value.value
              }])
            : envAcc),
        // 4. Ordinary connection values, unless an explicit variable uses the same name.
        filter(connectionEnvVars, envVar => !contains(item.value.?env ?? {}, envVar.name)),
        // 5. Platform variables from the Recipe Pack, unless an explicit variable uses the same name.
        filter(platformEnvVars, envVar => !contains(item.value.?env ?? {}, envVar.name)),
        // 6. LOCAL ADDITION. Where the service's own certificate is, when it has one.
        (!empty(serviceCertificateIssuer) && contains(item.value.?ports ?? {}, 'https')) ? [
          { name: 'TLS_CERT_FILE', value: '${serviceTlsDir}/tls.crt' }
          { name: 'TLS_KEY_FILE', value: '${serviceTlsDir}/tls.key' }
        ] : []
      )
    } : {},
    // Connections that surface secretName still inject that Kubernetes Secret via envFrom, followed
    // by the platform's Secrets. An explicit env entry wins over envFrom for the same name.
    length(concat(secretNameEnvFrom, platformConnectionEnvFrom, platformEnvFrom)) > 0 ? {
      envFrom: concat(secretNameEnvFrom, platformConnectionEnvFrom, platformEnvFrom)
    } : {},
    // Add volume mounts, plus the platform's mounts and the service's own certificate
    (contains(item.value, 'volumeMounts') || length(platformVolumeMounts) > 0 || (!empty(serviceCertificateIssuer) && contains(item.value.?ports ?? {}, 'https'))) ? {
      volumeMounts: concat(
        reduce(item.value.?volumeMounts ?? [], [], (vmAcc, vm) => concat(vmAcc, [{
          name: toLower(vm.volumeName)
          mountPath: vm.mountPath
        }])),
        platformVolumeMounts,
        (!empty(serviceCertificateIssuer) && contains(item.value.?ports ?? {}, 'https')) ? [
          { name: 'service-tls-${toLower(item.key)}', mountPath: serviceTlsDir, readOnly: true }
        ] : []
      )
    } : {},
    // Add command if specified
    contains(item.value, 'command') ? { command: item.value.command } : {},
    // Add args if specified
    contains(item.value, 'args') ? { args: item.value.args } : {},
    // Add working directory if specified
    contains(item.value, 'workingDir') ? { workingDir: item.value.workingDir } : {},
    // Add resources if specified
    contains(item.value, 'resources') ? {
      resources: union(
        contains(item.value.resources, 'limits') ? {
          limits: union(
            contains(item.value.resources.limits, 'cpu') ? { cpu: item.value.resources.limits.cpu } : {},
            contains(item.value.resources.limits, 'memoryInMib') ? { memory: '${item.value.resources.limits.memoryInMib}Mi' } : {}
          )
        } : {},
        contains(item.value.resources, 'requests') ? {
          requests: union(
            contains(item.value.resources.requests, 'cpu') ? { cpu: item.value.resources.requests.cpu } : {},
            contains(item.value.resources.requests, 'memoryInMib') ? { memory: '${item.value.resources.requests.memoryInMib}Mi' } : {}
          )
        } : {}
      )
    } : {},
    // Add liveness probe if specified and this is not an init container
    (!(item.value.?initContainer ?? false) && contains(item.value, 'livenessProbe')) ? {
      livenessProbe: union(
        contains(item.value.livenessProbe, 'exec') ? {
          exec: { command: item.value.livenessProbe.exec.command }
        } : {},
        contains(item.value.livenessProbe, 'httpGet') ? {
          httpGet: union(
            { port: item.value.livenessProbe.httpGet.port },
            contains(item.value.livenessProbe.httpGet, 'path') ? { path: item.value.livenessProbe.httpGet.path } : {},
            contains(item.value.livenessProbe.httpGet, 'scheme') ? { scheme: toUpper(string(item.value.livenessProbe.httpGet.scheme)) } : {},
            contains(item.value.livenessProbe.httpGet, 'httpHeaders') ? { httpHeaders: item.value.livenessProbe.httpGet.httpHeaders } : {}
          )
        } : {},
        contains(item.value.livenessProbe, 'tcpSocket') ? {
          tcpSocket: { port: item.value.livenessProbe.tcpSocket.port }
        } : {},
        contains(item.value.livenessProbe, 'initialDelaySeconds') ? { initialDelaySeconds: item.value.livenessProbe.initialDelaySeconds } : {},
        contains(item.value.livenessProbe, 'periodSeconds') ? { periodSeconds: item.value.livenessProbe.periodSeconds } : {},
        contains(item.value.livenessProbe, 'timeoutSeconds') ? { timeoutSeconds: item.value.livenessProbe.timeoutSeconds } : {},
        contains(item.value.livenessProbe, 'failureThreshold') ? { failureThreshold: item.value.livenessProbe.failureThreshold } : {},
        contains(item.value.livenessProbe, 'successThreshold') ? { successThreshold: item.value.livenessProbe.successThreshold } : {},
        contains(item.value.livenessProbe, 'terminationGracePeriodSeconds') ? { terminationGracePeriodSeconds: item.value.livenessProbe.terminationGracePeriodSeconds } : {}
      )
    } : {},
    // Add readiness probe if specified and this is not an init container
    (!(item.value.?initContainer ?? false) && contains(item.value, 'readinessProbe')) ? {
      readinessProbe: union(
        contains(item.value.readinessProbe, 'exec') ? {
          exec: { command: item.value.readinessProbe.exec.command }
        } : {},
        contains(item.value.readinessProbe, 'httpGet') ? {
          httpGet: union(
            { port: item.value.readinessProbe.httpGet.port },
            contains(item.value.readinessProbe.httpGet, 'path') ? { path: item.value.readinessProbe.httpGet.path } : {},
            contains(item.value.readinessProbe.httpGet, 'scheme') ? { scheme: toUpper(string(item.value.readinessProbe.httpGet.scheme)) } : {},
            contains(item.value.readinessProbe.httpGet, 'httpHeaders') ? { httpHeaders: item.value.readinessProbe.httpGet.httpHeaders } : {}
          )
        } : {},
        contains(item.value.readinessProbe, 'tcpSocket') ? {
          tcpSocket: { port: item.value.readinessProbe.tcpSocket.port }
        } : {},
        contains(item.value.readinessProbe, 'initialDelaySeconds') ? { initialDelaySeconds: item.value.readinessProbe.initialDelaySeconds } : {},
        contains(item.value.readinessProbe, 'periodSeconds') ? { periodSeconds: item.value.readinessProbe.periodSeconds } : {},
        contains(item.value.readinessProbe, 'timeoutSeconds') ? { timeoutSeconds: item.value.readinessProbe.timeoutSeconds } : {},
        contains(item.value.readinessProbe, 'failureThreshold') ? { failureThreshold: item.value.readinessProbe.failureThreshold } : {},
        contains(item.value.readinessProbe, 'successThreshold') ? { successThreshold: item.value.readinessProbe.successThreshold } : {},
        contains(item.value.readinessProbe, 'terminationGracePeriodSeconds') ? { terminationGracePeriodSeconds: item.value.readinessProbe.terminationGracePeriodSeconds } : {}
      )
    } : {}
  )
}]))

var podContainers = reduce(containerSpecs, [], (acc, container) => !(container.isInit ?? false) ? concat(acc, [container.spec]) : acc)
var podInitContainers = reduce(containerSpecs, [], (acc, container) => (container.isInit ?? false) ? concat(acc, [container.spec]) : acc)

// Add volume mounts
var volumeItems = items(resourceProperties.?volumes ?? {})
var podVolumes = reduce(volumeItems, [], (acc, vol) => concat(acc, [union(
  {
    name: toLower(vol.key)
  },
  contains(vol.value, 'persistentVolume') ? {
    persistentVolumeClaim: {
      // Extract the PVC name from the resourceId (last segment of the path)
      claimName: last(split(string(vol.value.persistentVolume.resourceId), '/'))
    }
  } : {},
  contains(vol.value, 'secretName') ? {
    secret: {
      secretName: vol.value.secretName
    }
  } : {},
  contains(vol.value, 'emptyDir') ? {
    emptyDir: contains(vol.value.emptyDir, 'medium') ? {
      medium: vol.value.emptyDir.medium == 'memory' ? 'Memory' : ''
    } : {}
  } : {},
  // A token minted for a named audience, which the kubelet rotates in place. This is what lets a
  // workload authenticate without holding a secret of its own.
  contains(vol.value, 'serviceAccountToken') ? {
    projected: {
      sources: [
        {
          serviceAccountToken: {
            audience: vol.value.serviceAccountToken.audience
            expirationSeconds: vol.value.serviceAccountToken.?expirationSeconds ?? 3600
            path: vol.value.serviceAccountToken.?path ?? 'token'
          }
        }
      ]
    }
  } : {}
)]))

// LOCAL ADDITION. A service account per resource, so each service has its own identity: on Azure
// its own managed identity (the webhook reads the client ID annotation), elsewhere its own subject
// in the projected token that an identity provider such as Keycloak matches.
resource serviceAccount 'core/ServiceAccount@v1' = if (createServiceAccount) {
  metadata: {
    name: platformServiceAccountName
    namespace: namespace
    labels: labels
    annotations: contains(workloadClientIds, resourceName) ? {
      'azure.workload.identity/client-id': string(workloadClientIds[resourceName])
    } : {}
  }
}

resource deployment 'apps/Deployment@v1' = {
  dependsOn: [ serviceAccount ]
  metadata: {
    name: normalizedName
    namespace: namespace
    labels: labels
  }
  spec: {
    replicas: replicaCount
    selector: {
      matchLabels: {
        'radapp.io/resource': resourceName
      }
    }
    template: {
      metadata: {
        // Pod labels from platformOptions are merged in; the workload-identity webhook keys off
        // `azure.workload.identity/use` here, on the pod, not on the ServiceAccount.
        labels: union(labels, platformPodLabels, platformConnectionPodLabels)
      }
      spec: union(
        {
          containers: podContainers
          // Disable K8s service env var injection to prevent collisions with app env vars.
          // Kubernetes auto-injects <SERVICE_NAME>_PORT=tcp://<ip>:<port> for every service in the namespace,
          // which can override app-defined env vars that developers explicitly set.
          // DNS-based service discovery (the modern K8s approach) is unaffected by this setting.
          enableServiceLinks: false
          // LOCAL ADDITION. No privileges, and replicas spread across nodes where there are enough
          // of them, so a node drain or failure takes only some of them.
          securityContext: platformPodSecurityContext
          topologySpreadConstraints: [
            {
              maxSkew: 1
              topologyKey: 'kubernetes.io/hostname'
              whenUnsatisfiable: 'ScheduleAnyway'
              labelSelector: {
                matchLabels: {
                  'radapp.io/resource': resourceName
                }
              }
            }
          ]
        },
        length(podInitContainers) > 0 ? { initContainers: podInitContainers } : {},
        length(concat(podVolumes, platformVolumes, serviceTlsVolumes)) > 0 ? { volumes: concat(podVolumes, platformVolumes, serviceTlsVolumes) } : {},
        contains(resourceProperties, 'restartPolicy') ? { restartPolicy: resourceProperties.restartPolicy } : {},
        // Binds the pod to the annotated ServiceAccount so Kubernetes mints a token whose `sub`
        // claim matches the federated identity credential.
        empty(platformServiceAccountName) ? {} : { serviceAccountName: platformServiceAccountName },
        // Lets the kubelet authenticate to a private registry, such as the in-cluster connected
        // registry on Azure Local.
        empty(platformImagePullSecrets) ? {} : { imagePullSecrets: platformImagePullSecrets }
      )
    }
  }
}

// Build service ports - one service per container that has ports
var servicesConfig = reduce(containerItems, [], (acc, item) => 
  contains(item.value, 'ports') && length(items(item.value.ports)) > 0 ? concat(acc, [{
    containerName: item.key
    normalizedContainerName: toLower(item.key)
    ports: reduce(items(item.value.ports), [], (portAcc, port) => concat(portAcc, [{
      name: toLower(port.key)
      port: port.value.containerPort
      targetPort: port.value.containerPort
      protocol: port.value.?protocol ?? 'TCP'
    }]))
  }]) : acc
)

resource services 'core/Service@v1' = [for svc in servicesConfig: {
  metadata: {
    name: '${normalizedName}-${svc.normalizedContainerName}'
    namespace: namespace
    labels: union(labels, {
      container: svc.containerName
    })
  }
  spec: {
    type: 'ClusterIP'
    selector: {
      'radapp.io/resource': resourceName
    }
    ports: svc.ports
  }
}]

// LOCAL ADDITION. The certificate of each container with an `https` port, for every name its
// Service answers to. cert-manager renews it a month before it expires.
#disable-next-line BCP081
resource serviceCertificates 'cert-manager.io/Certificate@v1' = [for item in serviceTlsContainers: {
  metadata: {
    name: '${normalizedName}-${toLower(item.key)}-tls'
    namespace: namespace
    labels: labels
  }
  spec: {
    secretName: '${normalizedName}-${toLower(item.key)}-tls'
    dnsNames: [
      '${normalizedName}-${toLower(item.key)}'
      '${normalizedName}-${toLower(item.key)}.${namespace}'
      '${normalizedName}-${toLower(item.key)}.${namespace}.svc'
      '${normalizedName}-${toLower(item.key)}.${namespace}.svc.cluster.local'
    ]
    usages: [ 'server auth' ]
    duration: '2160h'
    renewBefore: '720h'
    privateKey: {
      algorithm: 'ECDSA'
      size: 256
      rotationPolicy: 'Always'
    }
    issuerRef: {
      kind: 'ClusterIssuer'
      name: serviceCertificateIssuer
    }
  }
}]

// Add Horizontal Pod Autoscaler (if autoScaling specified)
var autoScaling = resourceProperties.?autoScaling
var hasAutoScaling = autoScaling != null

// Build HPA metrics
var hpaMetrics = hasAutoScaling && contains(autoScaling, 'metrics') ? reduce(autoScaling.metrics, [], (acc, metric) => concat(acc, [union(
  {
    type: metric.kind == 'cpu' || metric.kind == 'memory' ? 'Resource' : 'External'
  },
  metric.kind == 'cpu' || metric.kind == 'memory' ? {
    resource: {
      name: metric.kind
      target: union(
        {
          type: contains(metric.target, 'averageUtilization') ? 'Utilization' : contains(metric.target, 'averageValue') ? 'AverageValue' : 'Value'
        },
        contains(metric.target, 'averageUtilization') ? { averageUtilization: metric.target.averageUtilization } : {},
        contains(metric.target, 'averageValue') ? { averageValue: string(metric.target.averageValue) } : {},
        contains(metric.target, 'value') ? { value: string(metric.target.value) } : {}
      )
    }
  } : {},
  (metric.kind == 'custom' && contains(metric, 'customMetric')) ? {
    external: {
      metric: {
        name: metric.customMetric
      }
      target: union(
        {
          type: contains(metric.target, 'averageUtilization') ? 'Utilization' : contains(metric.target, 'averageValue') ? 'AverageValue' : 'Value'
        },
        contains(metric.target, 'averageUtilization') ? { averageUtilization: metric.target.averageUtilization } : {},
        contains(metric.target, 'averageValue') ? { averageValue: string(metric.target.averageValue) } : {},
        contains(metric.target, 'value') ? { value: string(metric.target.value) } : {}
      )
    }
  } : {}
)])) : []

resource hpa 'autoscaling/HorizontalPodAutoscaler@v2' = if (hasAutoScaling) {
  metadata: {
    name: normalizedName
    namespace: namespace
    labels: labels
  }
  spec: {
    scaleTargetRef: {
      apiVersion: 'apps/v1'
      kind: 'Deployment'
      name: normalizedName
    }
    minReplicas: minReplicas
    maxReplicas: hasAutoScaling && contains(autoScaling, 'maxReplicas') ? int(autoScaling.maxReplicas) : 10
    metrics: hpaMetrics
  }
}

// LOCAL ADDITION. With more than one replica, a node drain or upgrade takes them down one at a
// time, so the service stays up. With one, a budget would only block the drain.
var minReplicas = hasAutoScaling && contains(autoScaling, 'minReplicas') ? int(autoScaling.minReplicas) : replicaCount
var useDisruptionBudget = minReplicas > 1

resource disruptionBudget 'policy/PodDisruptionBudget@v1' = if (useDisruptionBudget) {
  metadata: {
    name: normalizedName
    namespace: namespace
    labels: labels
  }
  spec: {
    // Kubernetes IntOrString: a count must be an integer, so the Bicep type warning is a false positive.
    #disable-next-line BCP036
    maxUnavailable: 1
    selector: {
      matchLabels: {
        'radapp.io/resource': resourceName
      }
    }
  }
}

var deploymentResource = '/planes/kubernetes/local/namespaces/${namespace}/providers/apps/Deployment/${normalizedName}'
var serviceResources = reduce(servicesConfig, [], (acc, svc) => concat(acc, ['/planes/kubernetes/local/namespaces/${namespace}/providers/core/Service/${normalizedName}-${svc.normalizedContainerName}']))
var hpaResource = hasAutoScaling ? ['/planes/kubernetes/local/namespaces/${namespace}/providers/autoscaling/HorizontalPodAutoscaler/${normalizedName}'] : []
var disruptionBudgetResource = useDisruptionBudget ? ['/planes/kubernetes/local/namespaces/${namespace}/providers/policy/PodDisruptionBudget/${normalizedName}'] : []

var serviceAccountResource = createServiceAccount ? ['/planes/kubernetes/local/namespaces/${namespace}/providers/core/ServiceAccount/${platformServiceAccountName}'] : []

var serviceTlsResources = reduce(serviceTlsContainers, [], (acc, item) => concat(acc, [
  '/planes/kubernetes/local/namespaces/${namespace}/providers/cert-manager.io/Certificate/${normalizedName}-${toLower(item.key)}-tls'
  '/planes/kubernetes/local/namespaces/${namespace}/providers/core/Secret/${normalizedName}-${toLower(item.key)}-tls'
]))

var allResources = concat([deploymentResource], serviceResources, hpaResource, disruptionBudgetResource, serviceAccountResource, serviceTlsResources)

// Publish each port-exposing container's in-cluster Service DNS host as a read-only
// output so peers can address it by reference instead of hardcoding a Service name.
// `hosts` maps container name to its Service DNS host for every Service this resource
// creates, so peers reference `<peer>.properties.hosts.<containerName>`. The name is
// cluster-domain-independent (`<service>.<namespace>`), so it resolves regardless of
// the cluster's configured DNS domain.
var hostsMap = toObject(servicesConfig, svc => svc.containerName, svc => '${normalizedName}-${svc.normalizedContainerName}.${namespace}')

output result object = {
  resources: allResources
  values: empty(servicesConfig) ? {} : { hosts: hostsMap }
}
