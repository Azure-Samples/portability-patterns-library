// Publishes a Radius.Compute/routes resource through a Kubernetes Ingress. The application declares
// which container answers which path; the platform, through the Recipe Pack, decides how: the ingress
// class, the host name and the certificate. A container with no route stays cluster-internal.
//
// The route names its destination by container resource ID, container name and port. The Service it
// points at is the one recipes/kubernetes/kubernetes-containers.bicep creates for that container:
// '<resource name>-<container name>', listening on the container port.
//
// Supported: kind HTTP, matched on httpPath (prefix). An Ingress can't match on headers, method or
// query parameters, so a match that asks for them is left out rather than published more broadly
// than the application intended. A route left with no path at all (another kind, or only such
// matches) fails to deploy: Kubernetes rejects an Ingress rule without paths.

@description('Radius context object passed into the recipe.')
param context object

@description('Ingress class that publishes the route, such as nginx or webapprouting.kubernetes.azure.com.')
param ingressClassName string

@description('Host name the Ingress answers on when the route names none. Empty answers on any host, such as a bare IP address.')
param ingressHost string = ''

@description('Existing TLS Secret in the application namespace that the Ingress serves, or the Secret a certificate issuer writes into.')
param ingressTlsSecretName string = ''

@description('Annotations for the Ingress, for example a cert-manager issuer for the ingress class.')
param ingressAnnotations object = {}

extension kubernetes with {
  kubeConfig: ''
  namespace: context.runtime.kubernetes.namespace
} as kubernetes

var namespace = context.runtime.kubernetes.namespace
var routeName = toLower(context.resource.name)
var routeKind = context.resource.properties.?kind ?? 'HTTP'
var rules = context.resource.properties.rules

// Hosts the route asks for win over the platform's default.
var routeHostnames = context.resource.properties.?hostnames ?? []
var hosts = !empty(routeHostnames) ? routeHostnames : (empty(ingressHost) ? [] : [ ingressHost ])

var paths = routeKind != 'HTTP' ? [] : flatten(map(rules, rule => map(filter(rule.matches, match => empty(match.?httpHeaders ?? []) && empty(match.?httpQueryParams ?? []) && empty(match.?httpMethod ?? '')), match => {
  path: empty(match.?httpPath ?? '') ? '/' : match.httpPath
  pathType: 'Prefix'
  backend: {
    service: {
      name: '${toLower(last(split(rule.destinationContainer.resourceId, '/')))}-${toLower(rule.destinationContainer.containerName)}'
      port: {
        number: rule.destinationContainer.containerPort
      }
    }
  }
})))

var ingressRules = empty(hosts) ? [ { http: { paths: paths } } ] : map(hosts, host => {
  host: host
  http: { paths: paths }
})

resource ingress 'networking.k8s.io/Ingress@v1' = {
  metadata: {
    name: routeName
    namespace: namespace
    labels: {
      'radapp.io/resource': context.resource.name
      'radapp.io/application': context.application == null ? '' : context.application.name
    }
    annotations: ingressAnnotations
  }
  spec: union(
    {
      ingressClassName: ingressClassName
      rules: ingressRules
    },
    empty(ingressTlsSecretName) ? {} : {
      tls: [
        union(empty(hosts) ? {} : { hosts: hosts }, { secretName: ingressTlsSecretName })
      ]
    }
  )
}

output result object = {
  resources: [
    '/planes/kubernetes/local/namespaces/${namespace}/providers/networking.k8s.io/Ingress/${routeName}'
  ]
  values: {
    listener: union(
      empty(hosts) ? {} : { hostname: hosts[0] },
      {
        port: empty(ingressTlsSecretName) ? 80 : 443
        protocol: empty(ingressTlsSecretName) ? 'HTTP' : 'HTTPS'
      }
    )
  }
}
