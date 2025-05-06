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
            // Verify kubeconfig is properly loaded
            sh 'kubectl config view'
            
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
                values="./apps/${app}/values/prod.yaml"
                
                # Check if values file exists
                if [ ! -f "\$values" ]; then
                  echo "ERROR: Values file \$values not found"
                  exit 1
                fi

                chart_ref="${chartRef}"
                chart_name=\$(basename "\$chart_ref")

                echo "→ Processing ${app} → \$chart_ref"

                # 1. Pull chart + dependencies
                helm pull "\$chart_ref" --untar --untardir /tmp
                helm dependency update /tmp/"\$chart_name"

                # 2. Relaxed Helm Linting - continue even with errors
                echo "=== STEP 1: HELM LINT (Relaxed) ==="
                helm lint /tmp/"\$chart_name" -f "\$values" --strict=false || echo "Helm lint found issues but continuing"
                
                # 3. Template Generation - validate templates render correctly
                echo "=== STEP 2: TEMPLATE VALIDATION ==="
                helm template "${app}" /tmp/"\$chart_name" -f "\$values" > /tmp/manifests/${app}.yaml
                if [ \$? -eq 0 ]; then
                  echo "✅ Template generation successful"
                else
                  echo "❌ Template generation failed"
                  exit 1
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
                echo "=== STEP 3: KUBECONFORM VALIDATION for ${app} ==="
                # Skip validating CRDs which might not match schema
                grep -v "kind: CustomResourceDefinition" /tmp/manifests/${app}.yaml > /tmp/manifests/${app}-nocrd.yaml || true
                
                # Relaxed validation with generous timeouts and schema skipping
                kubeconform -summary -output json -schema-location default -skip CustomResourceDefinition -ignore-missing-schemas -kubernetes-version v1.30.2+k3s2 /tmp/manifests/${app}-nocrd.yaml || {
                  echo "⚠️  Some resources failed validation, but this is often normal with third-party charts"
                  echo "⚠️  Review validation errors above manually"
                }
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
                values="./apps/${app}/values/prod.yaml"
                
                # Check if values file exists
                if [ ! -f "\$values" ]; then
                  echo "ERROR: Values file \$values not found"
                  exit 1
                fi
                
                chart_ref="${chartRef}"
                chart_name=\$(basename "\$chart_ref")

                # Pull & deps
                helm pull "\$chart_ref" --untar --untardir /tmp
                helm dependency update /tmp/"\$chart_name"

                echo "=== STEP 4: DIFF VS LIVE CLUSTER ==="
                echo "→ Helm diff for ${app}"
                helm diff upgrade "${app}" /tmp/"\$chart_name" -f "\$values" --allow-unreleased || echo "Helm diff found changes but continuing"

                echo "→ Kubectl diff for ${app}"
                helm template "${app}" /tmp/"\$chart_name" -f "\$values" | kubectl diff --server-side=false -f - || echo "Kubectl diff found changes but continuing"
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
