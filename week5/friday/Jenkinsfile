// KijaniKiosk payments: CI pipeline
// Lint -> Build -> Verify (Test || Security Audit) -> Archive -> Publish
// Every build runs in the same pinned container; nothing is inherited from the host.

pipeline {
    agent {
        docker {
            image 'node:22.22.0-bookworm-slim'   // pinned: never 'latest'
        }
    }

    environment {
        NODE_ENV       = 'test'
        BUILD_DIR      = 'dist'
        APP_NAME       = 'kijanikiosk-payments'
        // The container runs as the jenkins user, which has no home directory
        // inside the image; npm needs a writable HOME for its cache.
        HOME           = "${env.WORKSPACE}"
        // Nexus runs on the Multipass host, reachable from the VM and its containers.
        // localhost would mean the container itself.
        NEXUS_REGISTRY = 'http://10.4.110.1:8081/repository/npm-kijanikiosk/'
    }

    options {
        timeout(time: 15, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '10'))
        // No disableConcurrentBuilds(): each build gets its own workspace and
        // publishes a version unique to its commit, so concurrent builds cannot
        // collide, and no developer's push is queued behind or merged into another's.
    }

    triggers {
        pollSCM('H/3 * * * *')   // Jenkins is not reachable from GitHub, so it polls
    }

    stages {
        // Fail fast: the cheapest check runs first
        stage('Lint') {
            steps {
                sh 'node --version && npm --version'
                echo "Installing dependencies for ${APP_NAME}..."
                sh 'npm ci'
                sh 'npm run lint'
            }
        }

        stage('Build') {
            steps {
                echo "Building application..."
                sh 'npm run build'

                // <semver>-<git-sha>: unique per commit and traceable to the source
                script {
                    def pkgVersion = sh(script: "node -p \"require('./package.json').version\"",
                                        returnStdout: true).trim()
                    def gitShort   = sh(script: 'echo "$GIT_COMMIT" | cut -c1-7',
                                        returnStdout: true).trim()
                    env.ARTIFACT_VERSION = "${pkgVersion}-${gitShort}"
                    currentBuild.displayName = "#${BUILD_NUMBER} ${env.ARTIFACT_VERSION}"
                }
                echo "Artifact version: ${ARTIFACT_VERSION}"

                // Stamp the version into the package now, so the artifact archived
                // in Jenkins is byte-for-byte the one published to Nexus
                sh '''
                    set -e
                    test -d "${BUILD_DIR}" || { echo "ERROR: build directory not found"; exit 1; }
                    cd "${BUILD_DIR}"
                    npm version "${ARTIFACT_VERSION}" --no-git-tag-version
                    echo "Build output: $(ls | wc -l) files in ${BUILD_DIR}/"
                '''
            }
        }

        // Independent checks run side by side. failFast is left off on purpose:
        // when one branch fails, the other still finishes, so the developer sees both results.
        stage('Verify') {
            parallel {
                stage('Test') {
                    steps {
                        echo "Running test suite for ${APP_NAME}..."
                        sh '''
                            set -e
                            npm test -- --ci
                        '''
                    }
                }
                stage('Security Audit') {
                    steps {
                        sh 'npm audit --audit-level=high'
                    }
                }
            }
        }

        stage('Archive') {
            steps {
                echo "Archiving ${APP_NAME} ${ARTIFACT_VERSION}..."
                archiveArtifacts artifacts: "${BUILD_DIR}/**",
                                 fingerprint: true,
                                 onlyIfSuccessful: true
                echo "Artifact archived. Download from: ${BUILD_URL}artifact/"
            }
        }

        stage('Publish') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'nexus-credentials',
                    usernameVariable: 'NEXUS_USER',
                    passwordVariable: 'NEXUS_PASS'
                )]) {
                    // Single quotes: the shell expands the variables, not Groovy,
                    // so the secret never appears in the pipeline script itself.
                    sh '''
                        set +x   # Jenkins traces every command by default; tracing would
                                 # print the base64 token, which masking cannot recognise
                        set -e
                        cd "${BUILD_DIR}"
                        trap 'rm -f .npmrc' EXIT   # .npmrc is removed even if publish fails

                        NEXUS_AUTH=$(printf '%s' "${NEXUS_USER}:${NEXUS_PASS}" | base64 -w0)
                        printf 'registry=%s\n%s:_auth=%s\n' \
                            "${NEXUS_REGISTRY}" "${NEXUS_REGISTRY#http:}" "${NEXUS_AUTH}" > .npmrc

                        echo "Publishing ${APP_NAME}@${ARTIFACT_VERSION} to ${NEXUS_REGISTRY}"
                        npm publish --tag ci

                        rm -f .npmrc
                        test ! -e .npmrc && echo ".npmrc removed"
                    '''
                }
            }
        }
    }

    post {
        always {
            // Diagnostics first: test results are published even when the build fails
            junit allowEmptyResults: true, testResults: 'test-results/*.xml'
            echo "Build URL: ${BUILD_URL}"
            echo "Total pipeline time: ${currentBuild.durationString.replace(' and counting', '')}"
            cleanWs()
        }
        success {
            echo "Pipeline succeeded: ${APP_NAME} ${env.ARTIFACT_VERSION} (build ${BUILD_NUMBER})"
            echo "Jenkins artifact: ${BUILD_URL}artifact/"
            echo "Nexus artifact:   ${NEXUS_REGISTRY}${APP_NAME}/-/${APP_NAME}-${env.ARTIFACT_VERSION}.tgz"
        }
        failure {
            // A team chat or email notification would be sent from here
            echo "NOTIFY: ${APP_NAME} build ${BUILD_NUMBER} FAILED - fixing it is the team's top priority. Log: ${BUILD_URL}console"
        }
        changed {
            // Fires only on transitions (green->red, red->green), avoiding alert fatigue
            echo "NOTIFY: ${APP_NAME} build status changed to ${currentBuild.currentResult} in build ${BUILD_NUMBER}"
        }
    }
}
