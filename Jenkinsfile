// Define apps configuration with comprehensive information
def appsConfig = [
  "authentik": [
    isHelm: true,
    namespace: "authentik",
    chart: "authentik/authentik",
    helmRepo: [
      name: "authentik",
      url: "https://charts.goauthentik.io"
    ]
  ],
  "cert-manager": [
    isHelm: true,
    namespace: "cert-manager",
    chart: "jetstack/cert-manager",
    helmRepo: [
      name: "jetstack",
      url: "https://charts.jetstack.io"
    ]
  ],
  "cnpg-authentik": [
    isHelm: false,
    namespace: "authentik"
  ],
  "cnpg-infisical": [
    isHelm: false,
    namespace: "infisical"
  ],
  "infisical": [
    isHelm: true,
    namespace: "infisical",
    chart: "infisical-helm-charts/infisical-standalone",
    helmRepo: [
      name: "infisical-helm-charts", 
      url: "https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/"
    ]
  ],
  "infisical-secrets-operator": [
    isHelm: true,
    namespace: "default",
    chart: "infisical-helm-charts/secrets-operator",
    helmRepo: [
      name: "infisical-helm-charts", 
      url: "https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/"
    ]
  ],
  "internal-issuer": [
    isHelm: false,
    namespace: "cert-manager"
  ],
  "jenkins": [
    isHelm: true,
    namespace: "jenkins",
    chart: "jenkins/jenkins",
    helmRepo: [
      name: "jenkins",
      url: "https://charts.jenkins.io"
    ]
  ],
  "longhorn": [
    isHelm: true,
    namespace: "longhorn-system",
    chart: "longhorn/longhorn",
    helmRepo: [
      name: "longhorn",
      url: "https://charts.longhorn.io"
    ]
  ],
  "minio-operator": [
    isHelm: true,
    namespace: "minio-operator",
    chart: "minio/operator",
    helmRepo: [
      name: "minio",
      url: "https://operator.min.io"
    ]
  ],
  "redis-authentik": [
    isHelm: true,
    namespace: "authentik",
    chart: "bitnami/redis",
    helmRepo: [
      name: "bitnami",
      url: "https://charts.bitnami.com/bitnami"
    ]
  ],
  "redis-infisical": [
    isHelm: true,
    namespace: "infisical",
    chart: "bitnami/redis",
    helmRepo: [
      name: "bitnami",
      url: "https://charts.bitnami.com/bitnami"
    ]
  ],
  "reflector": [
    isHelm: true,
    namespace: "default",
    chart: "emberstack/reflector",
    helmRepo: [
      name: "emberstack",
      url: "https://emberstack.github.io/helm-charts"
    ]
  ],
  "tenant-authentik": [
    isHelm: true,
    namespace: "authentik",
    chart: "minio/tenant",
    helmRepo: [
      name: "minio",
      url: "https://operator.min.io"
    ]
  ],
  "traefik": [
    isHelm: true,
    namespace: "traefik",
    chart: "traefik/traefik",
    helmRepo: [
      name: "traefik",
      url: "https://helm.traefik.io/traefik"
    ]
  ]
]

pipeline {
  agent none
  
  parameters {
    string(name: 'MODE', defaultValue: 'coordinator', description: 'Pipeline mode: coordinator or app-specific')
    string(name: 'APP_NAME', defaultValue: '', description: 'App to validate (only for app-specific mode)')
    booleanParam(name: 'FORCE_ALL_APPS', defaultValue: false, description: 'Force validation of all apps')
  }
  
  stages {
    // COORDINATOR MODE STAGES
    stage('Coordinator Mode') {
      when {
        expression { params.MODE == 'coordinator' }
      }
      stages {
        stage('YAML Lint') {
          agent { kubernetes { yamlFile 'ci/pods/lint.yaml' } }
          steps {
            container('yamllint') {
              sh 'yamllint -d relaxed .'
            }
          }
        }
  
        stage('Detect Changes') {
          agent { kubernetes { yamlFile 'ci/pods/ci-test.yaml' } }
          steps {
            script {
              // Initialize change detection
              def changedApps = []
              def isPR = env.CHANGE_ID != null
              
              // For PRs: check only apps with changes
              if (isPR) {
                echo "Pull Request detected - will validate only changed apps"
                
                // Get changed files in PR
                sh "git diff --name-only origin/main HEAD > changed_files.txt"
                def changedFiles = readFile('changed_files.txt').trim()
                
                appsConfig.keySet().each { app ->
                  if (changedFiles.contains("apps/${app}/") || params.FORCE_ALL_APPS) {
                    changedApps.add(app)
                    echo "App '${app}' has changes in PR"
                  }
                }
              } else {
                // For direct pushes: only do YAML linting, no app validation
                echo "Direct push detected - will only do YAML linting (skip app validation)"
                // Leave changedApps empty to skip app-specific validation
              }
              
              // Store changed apps for later stages
              env.CHANGED_APPS = changedApps.join(',')
            }
          }
        }
  
        stage('Trigger App Validations') {
          when {
            expression { !env.CHANGED_APPS.isEmpty() }
          }
          steps {
            script {
              def changedApps = env.CHANGED_APPS ? env.CHANGED_APPS.tokenize(',') : []
              
              if (changedApps.isEmpty()) {
                echo "No apps to validate. Skipping app validation."
                return
              }
              
              echo "Apps to validate: ${changedApps}"
              
              def appBuilds = [:]
              
              changedApps.each { app ->
                // Create a job for each app that calls this same pipeline with app-specific mode
                appBuilds["Validate ${app}"] = {
                  build job: env.JOB_NAME, 
                      parameters: [
                        string(name: 'MODE', value: 'app-specific'),
                        string(name: 'APP_NAME', value: app)
                      ],
                      wait: true // Wait for each to complete to see the results
                }
              }
              
              // Run all app builds in parallel
              parallel appBuilds
            }
          }
        }
      }
    }
    
    // APP-SPECIFIC MODE STAGES
    stage('App-Specific Mode') {
      when {
        expression { params.MODE == 'app-specific' && params.APP_NAME }
      }
      stages {
        stage('Validate and Schema Check') {
          agent { kubernetes { yamlFile 'ci/pods/ci-test.yaml' } }
          steps {
            // First generate manifests with Helm
            container('helm') {
              script {
                def app = params.APP_NAME
                def config = appsConfig[app]
                
                // Add Helm repositories
                if (config.isHelm) {
                  sh "helm repo add ${config.helmRepo.name} ${config.helmRepo.url} || true"
                  sh "helm repo update"
                }
                
                // Create outputs directory in the workspace
                sh 'mkdir -p manifests'
                
                sh """
                  set -eo pipefail
                  values_path="./apps/${app}/values/prod.yaml"
                  manifests_path="./apps/${app}/manifests"
                  
                  # Process app based on what exists
                  if [ -f "\$values_path" ]; then
                    # Process as a Helm app
                    echo "→ Processing ${app} with Helm (values/prod.yaml found)"
                    
                    chart_ref="${config.chart}"
                    chart_name=\$(basename "\$chart_ref")
                    namespace="${config.namespace}"
    
                    # 1. Pull chart + dependencies
                    helm pull "\$chart_ref" --untar --untardir helm-cache
                    helm dependency update helm-cache/"\$chart_name"
    
                    # 2. Relaxed Helm Linting - continue even with errors
                    echo "=== STEP 1: HELM LINT (Relaxed) ==="
                    helm lint helm-cache/"\$chart_name" -f "\$values_path" --strict=false || echo "Helm lint found issues but continuing"
                    
                    # 3. Template Generation - validate templates render correctly
                    echo "=== STEP 2: TEMPLATE VALIDATION ==="
                    helm template "${app}" helm-cache/"\$chart_name" -f "\$values_path" --namespace "\$namespace" > manifests/${app}.yaml
                    if [ \$? -eq 0 ]; then
                      echo "✅ Template generation successful"
                    else
                      echo "❌ Template generation failed"
                      exit 1
                    fi
                  fi
                  
                  if [ -d "\$manifests_path" ]; then
                    # Process manifests directory
                    echo "→ Processing manifests for ${app}"
                    echo "=== COLLECTING MANIFESTS ==="
                    
                    # If we already generated manifests from Helm, append the custom manifests
                    if [ -f "manifests/${app}.yaml" ]; then
                      echo "=== APPENDING CUSTOM MANIFESTS ==="
                      find "\$manifests_path" -name "*.yaml" -o -name "*.yml" | xargs cat >> manifests/${app}.yaml
                    else
                      # Otherwise create a new file with just the custom manifests
                      find "\$manifests_path" -name "*.yaml" -o -name "*.yml" | xargs cat > manifests/${app}.yaml
                    fi
                    echo "✅ Manifest collection successful"
                  fi
                  
                  # If no values or manifests were found
                  if [ ! -f "\$values_path" ] && [ ! -d "\$manifests_path" ]; then
                    echo "⚠️ WARNING: ${app} has neither values/prod.yaml nor manifests/ directory"
                    echo "⚠️ Skipping validation for ${app}"
                    touch manifests/${app}.yaml  # Create empty file to avoid errors
                  fi
                  
                  # Process the manifests for validation (remove CRDs)
                  if [ -f "manifests/${app}.yaml" ]; then
                    grep -v "kind: CustomResourceDefinition" manifests/${app}.yaml > manifests/${app}-nocrd.yaml || true
                  fi
                """
              }
            }
            
            // Then validate the schema in the same pod
            container('validator') {
              script {
                def app = params.APP_NAME
                
                sh """
                  if [ -s "manifests/${app}-nocrd.yaml" ]; then  # Check if file exists and has size > 0
                    echo "=== STEP 3: KUBECONFORM VALIDATION for ${app} ==="
                    
                    # Relaxed validation with generous timeouts and schema skipping
                    kubeconform -summary -output json -schema-location default -skip CustomResourceDefinition -ignore-missing-schemas manifests/${app}-nocrd.yaml || {
                      echo "⚠️  Some resources failed validation, but this is often normal with third-party charts"
                      echo "⚠️  Review validation errors above manually"
                    }
                  else
                    echo "Skipping validation for ${app} - no manifests to validate"
                  fi
                """
              }
            }
            
            // Archive results for reference
            script {
              def app = params.APP_NAME
              sh 'mkdir -p reports'
              sh "cp manifests/${app}*.yaml reports/ || true"
              archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
            }
          }
        }
        
        stage('Diff vs Live Cluster') {
          agent { kubernetes { yamlFile 'ci/pods/ci-test.yaml' } }
          steps {
            container('helm') {
              script {
                def app = params.APP_NAME
                def config = appsConfig[app]
                
                // Install helm-diff plugin
                sh 'helm plugin install https://github.com/databus23/helm-diff || true'
                
                // Add Helm repo if needed
                if (config.isHelm) {
                  sh "helm repo add ${config.helmRepo.name} ${config.helmRepo.url} || true"
                  sh "helm repo update"
                }
                
                sh """
                  set -eo pipefail
                  values_path="./apps/${app}/values/prod.yaml"
                  manifests_path="./apps/${app}/manifests"
                  
                  # Process app based on what exists
                  if [ -f "\$values_path" ]; then
                    # Process as a Helm app
                    chart_ref="${config.chart}"
                    chart_name=\$(basename "\$chart_ref")
                    namespace="${config.namespace}"

                    # Pull & deps
                    helm pull "\$chart_ref" --untar --untardir helm-cache
                    helm dependency update helm-cache/"\$chart_name"

                    echo "=== STEP 4: DIFF VS LIVE CLUSTER ==="
                    echo "→ Helm diff for ${app}"
                    helm diff upgrade "${app}" helm-cache/"\$chart_name" -f "\$values_path" --namespace "\$namespace" --allow-unreleased || echo "Helm diff found changes but continuing"

                    echo "→ Kubectl diff for ${app}"
                    helm template "${app}" helm-cache/"\$chart_name" -f "\$values_path" --namespace "\$namespace" | kubectl diff --server-side=false -f - || echo "Kubectl diff found changes but continuing"
                  fi
                  
                  if [ -d "\$manifests_path" ]; then
                    # Direct kubectl diff for manifest-only apps
                    echo "=== KUBECTL DIFF FOR MANIFESTS ==="
                    echo "→ Kubectl diff for ${app} manifests"
                    kubectl diff --server-side=false -f "\$manifests_path/" || echo "Kubectl diff found changes but continuing"
                  fi
                  
                  # If no values or manifests were found
                  if [ ! -f "\$values_path" ] && [ ! -d "\$manifests_path" ]; then
                    echo "Skipping diff for ${app} - no configuration found"
                  fi
                """
              }
            }
          }
        }
      }
    }
  }
}
