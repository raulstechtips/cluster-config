# ArgoCD Configuration Guide

This document outlines the complete setup, configuration, and troubleshooting steps for our ArgoCD installation with custom Config Management Plugins (CMP).

## Table of Contents

1. [Overview](#overview)
2. [Installation and Setup](#installation-and-setup)
3. [Config Management Plugins](#config-management-plugins)
   - [Kustomize with EnvSubst Plugin](#kustomize-with-envsubst-plugin)
   - [Environment Variables in Plugins](#environment-variables-in-plugins)
   - [Variable Substitution Strategy](#variable-substitution-strategy)
4. [Socket Permission Issue](#socket-permission-issue)
5. [Redis ConfigMap Substitution Issue](#redis-configmap-substitution-issue)
6. [Troubleshooting Guide](#troubleshooting-guide)
7. [Best Practices](#best-practices)
8. [References](#references)

## Overview

Our ArgoCD deployment is configured with a custom Config Management Plugin (CMP) that combines Kustomize and EnvSubst functionality, allowing for variable substitution in Kubernetes manifests. This enables a GitOps approach while still supporting dynamic configuration across environments.

## Installation and Setup

The installation consists of:

1. **Base ArgoCD HA Installation**
   - Uses upstream ArgoCD v3.0.0 HA manifest
   - Applied with Kustomize for customization

2. **Custom Components**
   - Custom Config Management Plugin for Kustomize with EnvSubst
   - Custom RBAC for the plugin
   - Ingress configuration
   - Secret management integration with Infisical

3. **Installation Process**
   - Deploy ArgoCD namespace 
   - Apply the kustomization manifest
   - Initialize with `argocd` CLI
   - Create and configure Applications

## Config Management Plugins

### Kustomize with EnvSubst Plugin

We've created a custom plugin that combines Kustomize for resource management with EnvSubst for variable substitution.

```yaml
# Base plugin configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: cmp-kustomize-envsubst
  namespace: argocd
data:
  plugin.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: kustomize-envsubst
    spec:
      generate:
        command: ["bash", "-c"]
        args:
          - |
            set -eo pipefail
            SHELL_FORMAT=$(printf '${%s} ' ${!ARGOCD_ENV_*})
            kustomize build --enable-helm --load-restrictor LoadRestrictionsNone . | envsubst "$SHELL_FORMAT"
```

The plugin runs in a sidecar container alongside the ArgoCD repo-server, installing necessary tools and fixing socket permissions.

### Environment Variables in Plugins

Environment variables are provided to the plugin exclusively through a secret reference:

1. **Via Secret Reference**
   ```yaml
   envFrom:
     - secretRef:
         name: argocd-app-env
   ```

2. **Example Environment Variables Structure**

   The following shows how environment variables are defined in our Infisical Secret:

   ```yaml
   apiVersion: secrets.infisical.com/v1alpha1
   kind: InfisicalSecret
   metadata:
     name: infisical-secret-argocd-app-env
     namespace: argocd
   spec:
     # Authentication and connection details...
     managedKubeSecretReferences:
       - secretName: argocd-app-env
         secretNamespace: argocd
         secretType: Opaque
         creationPolicy: Owner
         template:
           includeAllSecrets: false
           data:
             ARGOCD_ENV_ARGOCD_PROD_DOMAIN: "{{ .ARGOCD_APP.Value }}.{{ .DOMAIN.Value }}"
             ARGOCD_ENV_DOMAIN: "{{ .DOMAIN.Value }}"
             ARGOCD_ENV_INFISICAL_PROD_DOMAIN: "{{ .INFISICAL_APP.Value }}.{{ .DOMAIN.Value }}"
             ARGOCD_ENV_INFISICAL_PROD_HOST_API: "https://{{ .INFISICAL_APP.Value }}.{{ .DOMAIN.Value }}/api"
             # Additional environment variables...
   ```

All environment variables to be substituted should use the `ARGOCD_ENV_` prefix. This is enforced by our plugin implementation.

### Variable Substitution Strategy

We encountered an important issue with variable substitution - the plugin was overzealously replacing variables in system files like the Redis ConfigMaps. Our solution leverages bash's variable expansion capabilities:

1. **Dynamic Variable List**: We use `SHELL_FORMAT=$(printf '${%s} ' ${!ARGOCD_ENV_*})` to build a list of all variables starting with `ARGOCD_ENV_`
2. **Targeted Substitution**: We pass this list to `envsubst "$SHELL_FORMAT"` so it only substitutes those specific variables
3. **Base Image Switch**: We switched from Alpine to Ubuntu for better bash support

This approach prevents unintended substitution in system files while still allowing our application-specific variables to be replaced.

## Socket Permission Issue

A critical issue we encountered was socket permission errors between the ArgoCD repo-server and the CMP sidecar container.

### Problem

Socket permission errors manifested as:

```
rpc error: code = Unknown desc = plugin sidecar failed. couldn't find cmp-server plugin with name "kustomize-envsubst" supporting the given repository
```

And in logs:

```
error dialing to cmp-server for plugin kustomize-envsubst.sock, dial unix /home/argocd/cmp-server/plugins/kustomize-envsubst.sock: connect: permission denied
```

### Root Cause

The issue occurs because:

1. The ArgoCD repo-server container runs as the non-root `argocd` user (UID 999)
2. The CMP sidecar container creates socket files as the `root` user
3. The repo-server cannot access these socket files due to permission restrictions

### Solution

Our solution consists of:

1. A background process in the sidecar's postStart hook that:
   - Monitors for socket file creation
   - Changes permissions to `777` once created
   - Continues running to fix permissions if the socket is recreated

2. Setting the `ARGOCD_CMP_SERVER` environment variable on the repo-server:
   ```yaml
   env:
     - name: ARGOCD_CMP_SERVER
       value: "1"
   ```

This ensures proper communication between the containers.

## Redis ConfigMap Substitution Issue

We encountered an issue where variables in ArgoCD's Redis ConfigMaps were being incorrectly substituted by our plugin.

### Problem

When using `envsubst` without restrictions, it would replace variables like `${SERVICE}`, `${SENTINEL_PORT}`, etc. in Redis ConfigMaps, breaking the Redis functionality.

### Solution

We implemented a selective environment variable substitution approach:

1. **Define an Environment Variable Pattern**: Only variables with the `ARGOCD_ENV_` prefix are substituted
2. **Dynamic Shell Formatting**: Generate the list of variables at runtime
3. **Targeted Substitution**: Pass only this list to envsubst

```bash
set -eo pipefail
SHELL_FORMAT=$(printf '${%s} ' ${!ARGOCD_ENV_*})
kustomize build --enable-helm --load-restrictor LoadRestrictionsNone . | envsubst "$SHELL_FORMAT"
```

This approach prevents Redis variables from being substituted while still allowing our application variables to work.

## Troubleshooting Guide

If you encounter issues with the plugin:

### 1. Check Socket Permissions

```bash
kubectl exec -n argocd <repo-server-pod> -c kustomize-envsubst -- \
  ls -la /home/argocd/cmp-server/plugins/
```

The socket should have permissions set to `777`.

### 2. Verify Environment Variables

Check if environment variables are correctly passed to the plugin:

```bash
kubectl exec -n argocd <repo-server-pod> -c kustomize-envsubst -- \
  env | grep ARGOCD_ENV_
```

### 3. Test Variable Substitution

To test if variable substitution is working correctly:

```bash
kubectl exec -n argocd <repo-server-pod> -c kustomize-envsubst -- \
  sh -c 'echo "Test: ${ARGOCD_ENV_SOME_VAR}"'
```

### 4. Check for Redis ConfigMap Issues

If Redis components aren't working properly, check if variables have been incorrectly substituted:

```bash
kubectl get cm -n argocd argocd-redis-ha-configmap -o yaml
```

Look for empty values where variables like `${SERVICE}` should be.

### 5. Check Plugin Logs

```bash
kubectl logs -n argocd <repo-server-pod> -c kustomize-envsubst
kubectl logs -n argocd <repo-server-pod> -c argocd-repo-server
```

## Best Practices

1. **Environment Variable Naming**
   - Always prefix variables intended for substitution with `ARGOCD_ENV_`
   - Use descriptive names for better maintainability

2. **Secret Management**
   - Use Infisical for managing secrets and environment variables
   - Configure secrets with appropriate access controls

3. **Plugin Container Resources**
   - Adjust resource limits based on the complexity of your Kustomize manifests
   - Initial settings (128Mi/100m requests, 256Mi/200m limits) are conservative

4. **Testing Changes**
   - Always test plugin changes on non-critical applications first
   - Verify substitution behavior before applying to production

## References

- [ArgoCD Config Management Plugins Documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/config-management-plugins/)
- [ArgoCD Environment Variables](https://argo-cd.readthedocs.io/en/latest/user-guide/environment-variables/)
- [Kustomize Documentation](https://kubectl.docs.kubernetes.io/references/kustomize/)
- [EnvSubst Documentation](https://www.gnu.org/software/gettext/manual/html_node/envsubst-Invocation.html) 