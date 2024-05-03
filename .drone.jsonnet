local env = {
    workflow: "rf-all-atom",
    version: "1.0.0"
};

local checkForAutomatedCommit() = [
    {
        name: "check for [AUTOMATED] commit",
        image: "alpine/git",
        commands: [
            "if $(git log -1 | grep 'AUTOMATED_COMMIT' > .grep); then echo 'Found automated commit, exiting early' && exit 78; fi"
        ],
        when: {
            event: "push"
        },
    }
];

local buildAndPushImage(directory) = [
    {
        name: "build: " + directory,
        image: "plugins/gcr",
        environment: {
            ARTI_NAME: {
                from_secret: "arti_user"
            },
            ARTI_PASS: {
                from_secret: "arti_pass"
            },
        },
        privileged: true,
        resources: {
            requests: {
                memory: "1GB",
                cpu: 1000
            }
        },
        volumes: [
            {
                name: "cache",
                path: "/var/lib/docker",
            },
        ],
        settings: {
            registry: "gcr.io",
            repo: "cyrus-containers/" + env.workflow + "-" + directory,
            debug: true,
            context: directory,
            dockerfile: directory + "/Dockerfile",
            json_key: {
                from_secret: "drone-cyrus-containers-key"
            },
            build_args: [
                "VERSION=" + env.version
            ],
        },
        when: {
            event: "push"
        },
    },
    {
        name: "build (tag): " + directory,
        image: "plugins/gcr",
        environment: {
            ARTI_NAME: {
                from_secret: "arti_user"
            },
            ARTI_PASS: {
                from_secret: "arti_pass"
            },
        },
        privileged: true,
        resources: {
            requests: {
                memory: "1GB",
                cpu: 1000
            }
        },
        volumes: [
            {
                name: "cache",
                path: "/var/lib/docker",
            },
        ],
        settings: {
            registry: "gcr.io",
            repo: "cyrus-containers/" + env.workflow + "-" + directory,
            debug: true,
            context: directory,
            dockerfile: directory + "/Dockerfile",
            json_key: {
                from_secret: "drone-cyrus-containers-key"
            },
            build_args: [
                "VERSION=" + env.version
            ],
        },
        when: {
            event: "tag"
        },
    },
];

local getVersionTag() = [
    {
        name: "Get version (feature)",
        image: "ubuntu:latest",
        commands: [
            "echo " + env.version + "-$(echo $(echo $DRONE_BRANCH | tr / -)-$DRONE_BUILD_NUMBER) > .tags",
            "echo $(cat .tags)"
        ],
        when: {
            event: "push"
        }
    },
    {
        name: "Get version (master)",
        image: "ubuntu:latest",
        commands: [
            "echo " + env.version + " > .tags",
            "echo $(cat .tags)"
        ],
        when: {
            event: "tag"
        }
    }
];

local sshKeySetup() = [
    {
        name: "ssh key setup",
        image: "alpine/git",
        environment: {
            SSH_KEY: {
                from_secret: "github_ssh"
            },
        },
        commands: [
            'mkdir /root/.ssh',
            'echo -n "$SSHKEY" > /root/.ssh/id_rsa',
            'chmod 600 /root/.ssh/id_rsa',
            'touch /root/.ssh/known_hosts',
            'chmod 600 /root/.ssh/known_hosts',
            'ssh-keyscan -H github.com > /etc/ssh/ssh_known_hosts 2> /dev/null'
        ],
    }
];

local updateWorkflowImageTags() = [
    {
        name: "update workflow image tag versions",
        image: "python",
        commands: [
            "python ./update_workflow_image_tags.py -v $(cat .tags)",
        ],
    }
];

local pushToGitHub() = [
    {
        name: "push to github (push)",
        image: "alpine/git",
        commands: [
            'git add workflow.yaml',
            'git commit -q -m "[AUTOMATED_COMMIT] Updating image tags to version $(cat .tags) for workflow file" --allow-empty',
            'git push --set-upstream origin $DRONE_COMMIT_BRANCH'
        ],
        when: {
            event: "push"
        },
    }
];

local pushOpenAPISpec() = [
    {
        name: "push openapi to spec to artifactory",
        image: "appropriate/curl:latest",
        environment: {
            ARTI_NAME: {
                from_secret: "arti_user"
            },
            ARTI_PASS: {
                from_secret: "arti_pass"
            },
        },
        commands: [
            'curl -u $ARTI_NAME:$ARTI_PASS -T workflow.yaml "https://cyrusbio.jfrog.io/cyrusbio/argo-workflows/' + env.workflow + '/' + env.workflow + '-$(cat .tags).yaml"'
        ]
    },
];

# Add directory names under images/* that need to be built
local buildStages() = (
    buildAndPushImage("workflow-environment")
);

[
    {
        kind: "pipeline",
        name: env.workflow,
        type: "kubernetes",
        // This is necessary when docker caching is used to avoid weird concurrency issues
        concurrency: {
            limit: 1,
        },
        volumes: [
            {
                name: "cache",
                claim: {
                    name: "ai-folding-repo-cache",
                },
            },
        ],
        resources: {
            requests: {
                cpu: 1000,
                memory: "2Gi",
            }
        },
        node_selector: {
                    CPUs: 8
        },
        steps:  (
            checkForAutomatedCommit() +
            getVersionTag() +
            buildStages() +
            sshKeySetup() +
            updateWorkflowImageTags() +
            pushToGitHub() +
            pushOpenAPISpec()
        )
    }
]