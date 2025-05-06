pipeline {
  agent none

  // 2.1 Define your app→chart map here:
  //    Customize per-repo with any app names & their corresponding chart refs
  def chartMap = [
    cert-manager: "jetstack/cert-manager",
    infisical: "infisical/infisical",
  ]

  stages {

    // ── Stage 1: YAML Lint (Pushes only) ────────────────────────────────
    stage('YAML Lint') {
      when { not { changeRequest() } }
      agent { kubernetes { yamlFile 'ci/pods/lint.yaml' } }
      steps {
        container('yamllint') {
          sh 'yamllint -d relaxed app/'  // raw YAML check :contentReference[oaicite:15]{index=15}
        }
      }
    }

    // ── Stage 2: Helm Validate & Test (PR only) ─────────────────────────
    stage('Helm Validate & Test') {
      when { changeRequest() }
      agent { kubernetes { yamlFile 'ci/pods/ci-test.yaml' } }
      steps {
        container('yq') {
          sh 'echo "Apps to process:" && printf "%s\n" ' + chartMap.keySet().join(' ')
        }
        container('helm') {
          sh '''
            set -eo pipefail
            for app in ${chartMap.keySet().join(' ')}; do
              values="app/${app}/values.yaml"
              chart_ref="${chartMap[app]}"
              chart_name=$(basename "$chart_ref")

              echo "→ Processing $app → $chart_ref"

              # 1. Pull chart + dependencies
              helm pull "$chart_ref" --untar --untardir /tmp             # :contentReference[oaicite:16]{index=16}
              helm dependency update /tmp/"$chart_name"                  # :contentReference[oaicite:17]{index=17}

              # 2. Static lint & template
              helm lint /tmp/"$chart_name" -f "$values"                 # :contentReference[oaicite:18]{index=18}
              helm template "$chart_name" /tmp/"$chart_name" -f "$values" --debug >/dev/null  # :contentReference[oaicite:19]{index=19}

              # 3. Chart tests (jobs annotated helm.sh/hook:test)
              helm test "$chart_name" --timeout 5m                     # :contentReference[oaicite:20]{index=20}
            done
          '''
        }
      }
    }

    // ── Stage 3: Diff vs Live Cluster (PR only) ─────────────────────────
    stage('Diff vs Live Cluster') {
      when { changeRequest() }
      agent { kubernetes { yamlFile 'ci/pods/ci-test.yaml' } }
      steps {
        container('helm') {
          sh '''
            set -eo pipefail
            helm plugin install https://github.com/databus23/helm-diff       # :contentReference[oaicite:21]{index=21}

            for app in ${chartMap.keySet().join(' ')}; do
              values="app/${app}/values.yaml"
              chart_ref="${chartMap[app]}"
              chart_name=$(basename "$chart_ref")

              # Pull & deps
              helm pull "$chart_ref" --untar --untardir /tmp
              helm dependency update /tmp/"$chart_name"

              echo "→ Helm diff for $app"
              helm diff upgrade "$chart_name" /tmp/"$chart_name" -f "$values" --allow-unreleased  # :contentReference[oaicite:22]{index=22}

              echo "→ Kubectl diff for $app"
              helm template "$chart_name" /tmp/"$chart_name" -f "$values" \
                | kubectl diff --server-side=false -f -                        # :contentReference[oaicite:23]{index=23}
            done
          '''
        }
      }
    }

  }

  post {
    always {
      archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
    }
  }
}
