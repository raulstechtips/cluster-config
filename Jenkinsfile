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

    // ── Stage 2: Helm Validate & Test (PR only) ─────────────────────────
    stage('Helm Validate & Test') {
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
            
            chartMap.each { app, chartRef ->
              sh """
                set -eo pipefail
                values="./app/${app}/values.yaml"
                chart_ref="${chartRef}"
                chart_name=\$(basename "\$chart_ref")

                echo "→ Processing ${app} → \$chart_ref"

                # 1. Pull chart + dependencies
                helm pull "\$chart_ref" --untar --untardir /tmp
                helm dependency update /tmp/"\$chart_name"

                # 2. Static lint & template
                helm lint /tmp/"\$chart_name" -f "\$values"
                helm template "${app}" /tmp/"\$chart_name" -f "\$values" --debug >/dev/null
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
                values="./app/${app}/values.yaml"
                chart_ref="${chartRef}"
                chart_name=\$(basename "\$chart_ref")

                # Pull & deps
                helm pull "\$chart_ref" --untar --untardir /tmp
                helm dependency update /tmp/"\$chart_name"

                echo "→ Helm diff for ${app}"
                helm diff upgrade "${app}" /tmp/"\$chart_name" -f "\$values" --allow-unreleased || echo "Helm diff failed but continuing"

                echo "→ Kubectl diff for ${app}"
                helm template "${app}" /tmp/"\$chart_name" -f "\$values" | kubectl diff --server-side=false -f - || echo "Kubectl diff failed but continuing"
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
        archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
      }
    }

  }

}
