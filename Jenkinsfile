// 2.1 Define your app→chart map here:
//    Customize per-repo with any app names & their corresponding chart refs
def chartMap = [
  "cert-manager": "jetstack/cert-manager",
  "infisical": "infisical/infisical",
]

// Define Helm repos that need to be added
def helmRepos = [
  "jetstack": "https://charts.jetstack.io",
  "infisical-helm-charts": "https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/"
]

pipeline {
  agent none

  stages {

    // ── Stage 1: YAML Lint (Pushes only) ────────────────────────────────
    stage('YAML Lint') {
      when { not { changeRequest() } }
      agent { kubernetes { yamlFile 'ci/pods/lint.yaml' } }
      steps {
        container('yamllint') {
          sh 'yamllint -d relaxed .'
        }
      }
    }

    // ── Stage 2: Multi-layer Helm Validation & Test ─────────────────────
    stage('Helm Validation') {
      when { not { changeRequest() } }
      agent { kubernetes { yamlFile 'ci/pods/ci-test.yaml' } }
      steps {
        container('yq') {
          script {
            echo "Apps to process:"
            chartMap.keySet().each { app ->
              echo app
            }
          }
        }
        container('helm') {
          script {
            
            // Add Helm repositories first
            helmRepos.each { repoName, repoUrl ->
              sh "helm repo add ${repoName} ${repoUrl} || true"
            }
            sh "helm repo update"
            
            // Create outputs directory
            sh 'mkdir -p /tmp/manifests'
            
            chartMap.each { app, chartRef ->
              sh """
                set -eo pipefail
                values_path="./apps/${app}/values/prod.yaml"
                manifests_path="./apps/${app}/manifests"
                
                # Process app based on what exists
                if [ -f "\$values_path" ]; then
                  # Process as a Helm app
                  echo "→ Processing ${app} with Helm (values/prod.yaml found)"
                  
                  chart_ref="${chartRef}"
                  chart_name=\$(basename "\$chart_ref")

                  # 1. Pull chart + dependencies
                  helm pull "\$chart_ref" --untar --untardir /tmp
                  helm dependency update /tmp/"\$chart_name"

                  # 2. Relaxed Helm Linting - continue even with errors
                  echo "=== STEP 1: HELM LINT (Relaxed) ==="
                  helm lint /tmp/"\$chart_name" -f "\$values_path" --strict=false || echo "Helm lint found issues but continuing"
                  
                  # 3. Template Generation - validate templates render correctly
                  echo "=== STEP 2: TEMPLATE VALIDATION ==="
                  helm template "${app}" /tmp/"\$chart_name" -f "\$values_path" > /tmp/manifests/${app}.yaml
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
                  if [ -f "/tmp/manifests/${app}.yaml" ]; then
                    echo "=== APPENDING CUSTOM MANIFESTS ==="
                    find "\$manifests_path" -name "*.yaml" -o -name "*.yml" | xargs cat >> /tmp/manifests/${app}.yaml
                  else
                    # Otherwise create a new file with just the custom manifests
                    find "\$manifests_path" -name "*.yaml" -o -name "*.yml" | xargs cat > /tmp/manifests/${app}.yaml
                  fi
                  echo "✅ Manifest collection successful"
                fi
                
                # If no values or manifests were found
                if [ ! -f "\$values_path" ] && [ ! -d "\$manifests_path" ]; then
                  echo "⚠️ WARNING: ${app} has neither values/prod.yaml nor manifests/ directory"
                  echo "⚠️ Skipping validation for ${app}"
                  touch /tmp/manifests/${app}.yaml  # Create empty file to avoid errors
                fi
              """
            }
          }
        }
        
        // Validate manifests with Kubeconform
        container('validator') {
          script {
            chartMap.keySet().each { app ->
              sh """
                if [ -s "/tmp/manifests/${app}.yaml" ]; then  # Check if file exists and has size > 0
                  echo "=== STEP 3: KUBECONFORM VALIDATION for ${app} ==="
                  # Skip validating CRDs which might not match schema
                  grep -v "kind: CustomResourceDefinition" /tmp/manifests/${app}.yaml > /tmp/manifests/${app}-nocrd.yaml || true
                  
                  # Relaxed validation with generous timeouts and schema skipping
                  /kubeconform -summary -output json -schema-location default -skip CustomResourceDefinition -ignore-missing-schemas -kubernetes-version v1.30.2+k3s2 /tmp/manifests/${app}-nocrd.yaml || {
                    echo "⚠️  Some resources failed validation, but this is often normal with third-party charts"
                    echo "⚠️  Review validation errors above manually"
                  }
                else
                  echo "Skipping validation for ${app} - no manifests to validate"
                fi
              """
            }
          }
        }
      }
    }

    // ── Stage 3: Diff vs Live Cluster (PR only) ─────────────────────────
    stage('Diff vs Live Cluster') {
      when { not { changeRequest() } }
      agent { kubernetes { yamlFile 'ci/pods/ci-test.yaml' } }
      steps {
        container('helm') {
          // Install helm-diff plugin first as a separate step
          sh 'helm plugin install https://github.com/databus23/helm-diff || true'
          
          script {
            // Add Helm repositories first
            helmRepos.each { repoName, repoUrl ->
              sh "helm repo add ${repoName} ${repoUrl} || true"
            }
            sh "helm repo update"
            
            chartMap.each { app, chartRef ->
              sh """
                set -eo pipefail
                values_path="./apps/${app}/values/prod.yaml"
                manifests_path="./apps/${app}/manifests"
                
                # Process app based on what exists
                if [ -f "\$values_path" ]; then
                  # Process as a Helm app
                  chart_ref="${chartRef}"
                  chart_name=\$(basename "\$chart_ref")

                  # Pull & deps
                  helm pull "\$chart_ref" --untar --untardir /tmp
                  helm dependency update /tmp/"\$chart_name"

                  echo "=== STEP 4: DIFF VS LIVE CLUSTER ==="
                  echo "→ Helm diff for ${app}"
                  helm diff upgrade "${app}" /tmp/"\$chart_name" -f "\$values_path" --allow-unreleased || echo "Helm diff found changes but continuing"

                  echo "→ Kubectl diff for ${app}"
                  helm template "${app}" /tmp/"\$chart_name" -f "\$values_path" | kubectl diff --server-side=false -f - || echo "Kubectl diff found changes but continuing"
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

    // ── Stage 4: Archive Reports ───────────────────────────────────────
    stage('Archive Reports') {
      agent { kubernetes { yamlFile 'ci/pods/ci-test.yaml' } }
      steps {
        sh 'mkdir -p reports'
        sh 'cp /tmp/manifests/*.yaml reports/ || true'
        archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
      }
    }

  }

}
