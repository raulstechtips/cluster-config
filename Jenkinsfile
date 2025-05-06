pipeline {
  agent none
  stages {

    stage('Lint') {
      agent { kubernetes { yamlFile 'ci/pods/lint.yaml' } }
      steps {
        container('yamllint') { sh 'yamllint -d relaxed .'; }
        container('helm')     { sh 'helm lint chart/'; }
      }
    }

    stage('Chart Validation') {
      when { changeRequest() }   // true only for PR builds
      agent { kubernetes { yamlFile 'ci/pods/chart-test.yaml' } }
      steps {
        container('charttest') { sh 'ct lint --config ct.yaml && ct install --config ct.yaml'; }
        container('helm')      { sh 'helm test mychart --logs'; }
      }
    }
  }
}
