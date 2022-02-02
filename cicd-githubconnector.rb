{
  title: 'Workato CICD for Github testing',

  secure_tunnel: true,

  connection: {
    fields: [
      {
        name: 'connection_type',
        label: 'Connection type',
        hint: 'Select if GitHub is hosted on-prem or in cloud.',
        optional: false,
        control_type: 'select',
        pick_list: [
          %w[GitHub.com cloud],
          %w[On\ Premise onpremise]
        ]
      },
      {
        ngIf: "input.connection_type == 'onpremise'",
        name: 'hostname',
        label: 'GitHub hostname',
        control_type: 'url',
        hint: 'GitHub hostname for authentication and API interactions. '\
        'Enter your on-prem enterprise edition hostname.',
        optional: false
      },
      {
        name: 'client_id',
        label: 'Client ID',
        optional: false,
        hint: '<a href="https://docs.github.com/en/developers/apps/building-oauth-apps/creating-an-oauth-app" '\
        'target="_blank">Learn more</a> about setting up OAuth 2.0 for your GitHub account.'
      },
      {
        name: 'client_secret',
        label: 'Client secret',
        optional: false,
        control_type: 'password'
      },
      {
        name: 'base_branch_name',
        label: 'Base branch name',
        hint: 'Select the name of your base branch.',
        optional: false,
        control_type: 'select',
        pick_list: [
          %w[Main main],
          %w[Master master]
        ],
        default: 'main'
      },
      {
        name: 'repo_owner',
        label: 'Repository owner name',
        hint: 'E.g., octocat is owner for repository https://github.com/octocat/hello-world.',
        optional: false,
        control_type: 'text'
      }
    ],

    authorization: {
      type: 'oauth2',

      authorization_url: lambda do |connection|
        github_hostname = connection['connection_type'] == 'cloud' ? 'https://github.com' : connection['hostname']
        "#{github_hostname}/login/oauth/authorize?scope=repo"
      end,

      token_url: lambda do |connection|
        github_hostname = connection['connection_type'] == 'cloud' ? 'https://github.com' : connection['hostname']
        "#{github_hostname}/login/oauth/access_token"
      end,

      client_id: lambda do |connection|
        connection['client_id']
      end,

      client_secret: lambda do |connection|
        connection['client_secret']
      end,

      acquire: lambda do |connection, auth_code|
        github_hostname = connection['connection_type'] == 'cloud' ? 'https://github.com' : connection['hostname']
        post("#{github_hostname}/login/oauth/access_token")
          .payload(
            client_id: (connection['client_id']).to_s,
            client_secret: (connection['client_secret']).to_s,
            code: auth_code,
            redirect_uri: 'https://www.workato.com/oauth/callback'
          ).headers(Accept: 'application/json')
      end,

      detect_on: [401],

      refresh_on: [401],

      apply: lambda do |_connection, access_token|
        headers(Authorization: "token #{access_token}",
                Accept: 'application/vnd.github.v3+json')
      end
    },

    base_uri: lambda do |connection|
      connection['connection_type'] == 'cloud' ? 'https://api.github.com/' : "#{connection['hostname']}/api/v3/"
    end

  },

  test: lambda do |_connection|
    get('repositories')
  end,

  object_definitions: {
    release_details_output: {
      fields: lambda do |_connection, _|
        [
          {
            name: 'release_name',
            label: 'Release name'
          },
          {
            name: 'release_version',
            label: 'Release version'
          },
          {
            name: 'release_manifest',
            label: 'Release manifest ID'
          },
          {
            name: 'release_package',
            label: 'Release package ID'
          },
          {
            name: 'release_refs',
            label: 'Release references'
          }
        ]
      end
    }
  },

  actions: {
    create_branch_ref: {
      title: 'Create branch',
      subtitle: 'Create branch reference in GitHub',

      help: 'Please note that you are unable to create new references for empty repositories. ' \
      'Empty repositories are repositories without branches. Please ensure that main branch is ' \
      'intialized in target repo before using this action. New branch reference uses main branch as a base.',

      description: lambda do |input|
        "Create <span class='provider'>branch</span> in " \
        "GitHub <span class='provider'>#{input['repo_name']}</span>"
      end,

      input_fields: lambda do |_object_definitions|
        [
          {
            name: 'repo_name',
            label: 'Repository name',
            hint: 'Target GitHub repository name to create new branch to facilitate pull request and package release.',
            optional: false
          },
          {
            name: 'branch_name',
            label: 'New branch name',
            hint: 'Unique branch name such as feature-customer-sync or feature-jira-4530.',
            optional: false
          }
        ]
      end,

      execute: lambda do |connection, input|
        main_sha = ''
        # Get main branch SHA1
        # https://docs.github.com/en/rest/reference/git#get-a-reference
        main_sha_response = get("repos/#{connection['repo_owner']}/#{input['repo_name']}/git/refs/heads/#{connection['base_branch_name']}")
                            .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}")
        end

        main_sha_response.after_response do |code, body, _headers|
          main_sha = body['object']['sha'] if code == 200
          # Create reference branch
          # https://docs.github.com/en/rest/reference/git#create-a-reference
          unless main_sha.to_s.strip.blank?
            ref = post("repos/#{connection['repo_owner']}/#{input['repo_name']}/git/refs", {
                         ref: "refs/heads/#{input['branch_name']}",
                         sha: main_sha
                       })
                  .after_response do |_code, ref_body, _headers|
              {
                branch_reference: ref_body['ref'],
                branch_reference_sha: ref_body['object']['sha']
              }
            end

            ref.after_error_response(/.*/) do |_, ref_body, _, message|
              error("#{message}: #{ref_body}")
            end
          end
        end
      end,

      output_fields: lambda do |_connection|
        [
          {
            control_type: 'text',
            label: 'Branch reference',
            type: 'string',
            name: 'branch_reference'
          },
          {
            control_type: 'text',
            label: 'Branch reference SHA',
            type: 'string',
            name: 'branch_reference_sha'
          }
        ]
      end
    },

    create_file_blob: {
      title: 'Create blob',
      subtitle: 'Create blob for files in GitHub',

      help: 'A Git blob (binary large object) is the object type used to '\
      'store the contents of each file in a repository. ',

      description: lambda do |input|
        "Create <span class='provider'>blob</span> in " \
        "GitHub <span class='provider'>#{input['repo_name']}</span>"
      end,

      input_fields: lambda do |_object_definitions|
        [
          {
            name: 'repo_name',
            label: 'Repository name',
            hint: 'Target GitHub repository name to create blob for a given file.',
            optional: false
          },
          {
            name: 'file_contents',
            label: 'File contents',
            hint: 'File to be stored as blob in GitHub repo. Contents will be base64 encoded.',
            optional: false
          }
        ]
      end,

      execute: lambda do |connection, input|
        # Create a file blob in GitHub DB
        # https://docs.github.com/en/rest/reference/git#create-a-blob
        blob = post("repos/#{connection['repo_owner']}/#{input['repo_name']}/git/blobs", {
                      content: input['file_contents'].encode_base64,
                      encoding: 'base64'
                    })
               .after_response do |_code, body, _headers|
          {
            blob_sha: body['sha']
          }
        end

        blob.after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}")
        end
      end,

      output_fields: lambda do |_connection|
        [
          {
            control_type: 'text',
            label: 'Blob SHA',
            type: 'string',
            name: 'blob_sha'
          }
        ]
      end
    },

    commit_new_branch: {
      title: 'Commit branch',
      subtitle: 'Commit new branch in GitHub',

      help: 'A Git commit is a snapshot of the hierarchy (Git tree) and the contents of the files (Git blob) in a Git repository.',

      description: lambda do |input|
        "Commit <span class='provider'>branch</span> in " \
        "GitHub <span class='provider'>#{input['repo_name']}</span>"
      end,

      input_fields: lambda do |_object_definitions|
        [
          {
            name: 'repo_name',
            label: 'Repository name',
            hint: 'Target GitHub repository.',
            optional: false
          },
          {
            control_type: 'text',
            label: 'Branch reference',
            type: 'string',
            name: 'branch_reference',
            optional: false,
            hint: 'The new branch reference.'
          },
          {
            control_type: 'text',
            label: 'Branch reference SHA',
            type: 'string',
            name: 'branch_reference_sha',
            optional: false,
            hint: 'The SHA1 value for new branch reference.'
          },
          {
            name: 'git_tree',
            type: 'array',
            of: 'object',
            label: 'Git blob list',
            optional: false,
            list_mode_toggle: true,
            list_mode: 'dynamic',
            hint: 'A Git tree object creates the hierarchy between files in a Git repository. ' \
            'Use blob list to populate this object.',
            properties: [
              {
                control_type: 'text',
                label: 'File path',
                name: 'path',
                type: 'string',
                optional: false,
                hint: 'The path for referenced file in the tree.'
              },
              {
                control_type: 'text',
                label: 'File mode',
                name: 'mode',
                type: 'string',
                optional: false,
                default: '100644',
                hint: 'The file mode; one of 100644 for file (blob), 100755 for executable (blob), ' \
                '040000 for subdirectory (tree), 160000 for submodule (commit), or 120000 for a blob ' \
                'that specifies the path of a symlink.'
              },
              {
                control_type: 'text',
                label: 'File type',
                name: 'type',
                type: 'string',
                optional: false,
                default: 'blob',
                hint: 'Either blob, tree, or commit.'
              },
              {
                control_type: 'text',
                label: 'File sha',
                name: 'sha',
                type: 'string',
                optional: false,
                hint: 'The SHA1 checksum ID of the blob object.'
              }
            ]
          },
          {
            control_type: 'select',
            label: 'Release type',
            type: 'string',
            name: 'release_type',
            toggle_hint: 'Select from list',
            pick_list: [
              %w[Major major],
              %w[Minor minor],
              %w[Patch patch]
            ],
            toggle_field: {
              name: 'release_type',
              label: 'Release type',
              type: 'string',
              control_type: 'text',
              optional: false,
              toggle_hint: 'Custom value'
            },
            optional: false,
            hint: 'Release type. Used for automatic release versioning upon pull request approval.'
          },
          {
            control_type: 'text',
            label: 'Mainfest ID',
            type: 'string',
            name: 'manifest_id',
            optional: false,
            hint: 'Mainfest ID used for current releases.'
          },
          {
            control_type: 'text',
            label: 'Package ID',
            type: 'string',
            name: 'package_id',
            optional: false,
            hint: 'Exported package ID for current releases.'
          },
          {
            control_type: 'text',
            label: 'Reference ID',
            type: 'string',
            name: 'reference_id',
            optional: true,
            hint: 'Any reference ID, e.g., Jira issue # AUTO-321.'
          },
          {
            control_type: 'text',
            label: 'Release message',
            type: 'string',
            name: 'release_message',
            optional: false,
            hint: 'Describe what changed in this release.'
          },
          {
            control_type: 'text',
            label: 'Commit author name',
            type: 'string',
            name: 'commit_author_name',
            optional: false,
            hint: 'Commit author name.'
          },
          {
            control_type: 'text',
            label: 'Commit author email',
            type: 'string',
            name: 'commit_author_email',
            optional: false,
            hint: 'Commit author email address.'
          },
          {
            label: 'Continuous delivery',
            type: 'string',
            name: 'continuous_delivery',
            control_type: 'select',
            toggle_hint: 'Select from list',
            pick_list: [
              %w[Yes yes],
              %w[No no]
            ],
            toggle_field: {
              name: 'continuous_delivery',
              label: 'Continuous delivery',
              type: 'string',
              control_type: 'text',
              optional: false,
              toggle_hint: 'Custom value'
            },
            optional: false,
            hint: 'Select if package should be imported in test environment.'
          },
          {
            control_type: 'text',
            label: 'Folder ID',
            type: 'string',
            name: 'folder_id',
            optional: true,
            hint: 'Test environment folder ID for continuous delivery.'
          }
        ]
      end,

      execute: lambda do |connection, input|
        # https://docs.github.com/en/rest/reference/git#get-a-commit
        new_reference_commit = get("repos/#{connection['repo_owner']}/#{input['repo_name']}/git/commits/#{input['branch_reference_sha']}")
                               .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}")
        end

        new_reference_commit.after_response do |code, body, _headers|
          base_sha = body['sha'] || ''
          base_tree_sha = body['tree']['sha'] if code == 200

          # https://docs.github.com/en/rest/reference/git#create-a-tree
          create_git_tree = post("repos/#{connection['repo_owner']}/#{input['repo_name']}/git/trees", {
                                   tree: input['git_tree'],
                                   base_tree: base_tree_sha
                                 })
                            .after_error_response(/.*/) do |_, tree_body, _, message|
            error("#{message}: #{tree_body}")
          end

          create_git_tree.after_response do |_code, tree_body, _headers|
            committer_obj = {
              name: input['commit_author_name'].to_s,
              email: input['commit_author_email']
            }

            # Important: Store the commit message in YAML with necessary details to automate CD steps of release creation and deployments
            # Based on semantic versioning and conventional commit specifications
            commit_message = ''
            commit_message = if input['release_type'].upcase.include?('MAJOR')
                               "#{commit_message}BREAKING-CHANGE: #{input['release_message']}\n"
                             elsif input['release_type'].upcase.include?('MINOR')
                               "#{commit_message}feat: #{input['release_message']}\n"
                             else
                               "#{commit_message}fix: #{input['release_message']}\n"
                             end

            commit = commit + "manifest: #{input['manifest_id']} \n" unless input['manifest_id'].nil?
            commit = commit + "package: #{input['package_id']} \n" unless input['package_id'].nil?
            commit = commit + "refs: #{input['reference_id']} \n" unless input['reference_id'].nil?
            commit = commit + "CD: #{input['continuous_delivery']} \n" unless input['continuous_delivery'].nil?
            commit = commit + "test_folder: #{input['folder_id']} \n" unless input['folder_id'].nil?

            # https://docs.github.com/en/rest/reference/git#create-a-commit
            commit = post("repos/#{connection['repo_owner']}/#{input['repo_name']}/git/commits", {
                            message: commit_message,
                            author: committer_obj,
                            committer: committer_obj,
                            tree: tree_body['sha'],
                            parents: [base_sha.to_s]
                          })
                     .after_response do |_code, commit_body, _headers|
              # https://docs.github.com/en/rest/reference/git#update-a-reference
              reference = patch("repos/#{connection['repo_owner']}/#{input['repo_name']}/git/#{input['branch_reference']}", {
                                  sha: commit_body['sha']
                                })
                          .after_response do |_code, ref_body, _headers|
                {
                  branch_reference: ref_body['ref']
                }
              end

              reference.after_error_response(/.*/) do |_, ref_body, _, message|
                error("#{message}: #{ref_body}")
              end
            end

            commit.after_error_response(/.*/) do |_, commit_body, _, message|
              error("#{message}: #{commit_body}")
            end
          end
        end
      end, # execute.end

      output_fields: lambda do |_connection|
        [
          {
            control_type: 'text',
            label: 'Branch reference',
            type: 'string',
            name: 'branch_reference'
          }
        ]
      end

    },

    create_pull_request: {
      title: 'Create pull request',
      subtitle: 'Create pull request in GitHub',

      help: "Pull requests let you tell others about changes you've pushed to a branch in a repository on GitHub. " \
      'Once a pull request is opened, you can discuss and review the potential changes with collaborators. ' \
      'Once approved, you can merge feature branch with base branch to continue CI/CD process.',

      description: lambda do |input|
        "Create <span class='provider'>pull request</span> in " \
        "GitHub <span class='provider'>#{input['repo_name']}</span>"
      end,

      input_fields: lambda do |_object_definitions|
        [
          {
            name: 'repo_name',
            label: 'Repository name',
            hint: 'Target GitHub repository name to create pull request.',
            optional: false
          },
          {
            control_type: 'text',
            label: 'Pull request title',
            type: 'string',
            name: 'pull_request_title',
            optional: false,
            hint: 'The title of the new pull request.'
          },
          {
            control_type: 'text',
            label: 'Branch name',
            type: 'string',
            name: 'head_branch_name',
            optional: false,
            hint: 'The name of the branch where your changes are implemented.'
          },
          {
            control_type: 'text',
            label: 'Reviewer username',
            type: 'string',
            name: 'reviewer_username',
            optional: true,
            hint: 'Reviewer user name. Use comma separated list for multiple reviewers.'
          }
        ]
      end,

      execute: lambda do |connection, input|
        # https://docs.github.com/en/rest/reference/pulls#create-a-pull-request
        pull_request = post("repos/#{connection['repo_owner']}/#{input['repo_name']}/pulls", {
                              title: input['pull_request_title'],
                              head: input['head_branch_name'],
                              base: connection['base_branch_name']
                            })
                       .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}")
        end

        pull_request.after_response do |_code, body, _headers|
          response = {
            'pull_request_number' => body['number'],
            'pull_request_id' => body['id'],
            'pull_request_url' => body['html_url']
          }

          if (input['reviewer_username']).to_s.blank?
            response
          else
            # https://docs.github.com/en/rest/reference/pulls#request-reviewers-for-a-pull-request
            reviewer = post("repos/#{connection['repo_owner']}/#{input['repo_name']}/pulls/#{response['pull_request_number']}/requested_reviewers", {
                              reviewers: input['reviewer_username'].split(',')
                            })
                       .after_error_response(/.*/) do |_, _body, _, _message|
              response['reviewer_assigned'] = false
              response
            end

            reviewer.after_response do |_code, _body, _headers|
              response['reviewer_assigned'] = true
              response
            end

          end
        end
      end, # execute.end

      output_fields: lambda do |_connection|
        [
          {
            control_type: 'text',
            label: 'Pull request number',
            type: 'string',
            name: 'pull_request_number'
          },
          {
            control_type: 'text',
            label: 'Pull request ID',
            type: 'string',
            name: 'pull_request_id'
          },
          {
            control_type: 'text',
            label: 'Pull request link',
            type: 'string',
            name: 'pull_request_url'
          },
          {
            control_type: 'text',
            label: 'Reviewer assigned',
            type: 'boolean',
            name: 'reviewer_assigned'
          }
        ]
      end
    },

    create_new_release: {
      title: 'Create release',
      subtitle: 'Create release in GitHub',

      help: 'Uses pull request commit message to automatically determine release version, ' \
      'release notes, and creates a new release.',

      description: lambda do |input|
        "Create <span class='provider'>release</span> in " \
        "GitHub <span class='provider'>#{input['repo_name']}</span>"
      end,

      input_fields: lambda do |_object_definitions|
        [
          {
            name: 'repo_name',
            label: 'Repository name',
            hint: 'GitHub repository name.',
            optional: false
          },
          {
            name: 'release_name',
            label: 'Release name',
            hint: 'Give a name to the release.',
            optional: false
          },
          {
            name: 'pr_number',
            label: 'Pull request number',
            hint: 'Pull request number for current event.',
            optional: false
          },
          {
            name: 'pr_url',
            label: 'Pull request link',
            hint: 'Pull request link for tracking in release notes.',
            optional: false
          }
        ]
      end,

      execute: lambda do |connection, input|
        # https://docs.github.com/en/rest/reference/repos#get-the-latest-release
        get_latest_release = get("repos/#{connection['repo_owner']}/#{input['repo_name']}/releases/latest")
                             .after_error_response(/.*/) do |code, body, _, message|
                               if code.to_s > '299' && code.to_s != '404'
                                 error("#{message}: #{body}")
                               else
                                 # 404 denotes this is the first release
                                 call('create_next_release', connection, input, '')
                               end
                             end

        get_latest_release.after_response do |_code, body, _headers|
          call('create_next_release', connection, input, body['tag_name'])
        end
      end, # execute.end

      output_fields: lambda do |_connection|
        [
          {
            control_type: 'text',
            label: 'Release version',
            type: 'string',
            name: 'release_version'
          },
          {
            control_type: 'text',
            label: 'Release link',
            type: 'string',
            name: 'release_url'
          },
          {
            control_type: 'text',
            label: 'Release log',
            type: 'string',
            name: 'release_log'
          },
          {
            control_type: 'text',
            label: 'Release manifest ID',
            type: 'string',
            name: 'release_manifest'
          },
          {
            control_type: 'text',
            label: 'Release package ID',
            type: 'string',
            name: 'release_package'
          },
          {
            control_type: 'text',
            label: 'Release references',
            type: 'string',
            name: 'release_refs'
          },
          {
            control_type: 'text',
            label: 'Continuous delivery',
            type: 'string',
            name: 'continuous_delivery'
          },
          {
            control_type: 'text',
            label: 'Test folder',
            type: 'string',
            name: 'test_folder'
          }
        ]
      end

    }, # create_new_release.end

    list_recent_release: {

      title: 'List releases',
      subtitle: 'List releases from GitHub',

      help: 'Returns a list of published releases. Use the published release version for a manual deployment.',

      description: lambda do |input|
        "List <span class='provider'>releases</span> in " \
        "GitHub <span class='provider'>#{input['repo_name']}</span>"
      end,

      input_fields: lambda do |_object_definitions|
        [
          {
            name: 'repo_name',
            label: 'Repository name',
            hint: 'GitHub repository name.',
            optional: false
          },
          {
            name: 'release_per_page',
            label: 'List size',
            hint: 'Select how many recent releases to be listed.',
            optional: false,
            control_type: 'select',
            pick_list: [
              %w[5 5],
              %w[10 10],
              %w[20 20]
            ],
            default: '5'
          }
        ]
      end,

      execute: lambda do |connection, input|
        puts connection
        # https://docs.github.com/en/rest/reference/repos#list-releases
        get("repos/#{connection['repo_owner']}/#{input['repo_name']}/releases?page=1&per_page=#{input['release_per_page']}")
          .after_error_response(/.*/) do |_code, body, _, message|
          error("#{message}: #{body}")
        end
          .after_response do |_code, body, _headers|
          release_list = []

          body.each do |release|
            next unless call('valid_yaml', release['body'])

            release_details = workato.parse_yaml(release['body'])
            release_list.push({
                                release_name: release['name'].to_s,
                                release_version: release['tag_name'].to_s,
                                release_manifest: release_details['manifest'].to_s || '',
                                release_package: release_details['package'].to_s || '',
                                release_refs: release_details['refs'].to_s || ''
                              })
            # if.end
          end

          { release_list: release_list }
        end
      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            control_type: 'key_value',
            label: 'Release list',
            name: 'release_list',
            type: 'array',
            of: 'object',
            properties: object_definitions['release_details_output']
          }
        ]
      end
    }, # list_recent_releases.end

    get_release: {

      title: 'Get release',
      subtitle: 'Get release from GitHub',

      help: 'Returns a specificed release from GitHub repo. Use the published release version for a manual deployment.',

      description: lambda do |input|
        "Get <span class='provider'>release</span> from " \
        "GitHub <span class='provider'>#{input['repo_name']}</span>"
      end,

      input_fields: lambda do |_object_definitions|
        [
          {
            name: 'repo_name',
            label: 'Repository name',
            hint: 'GitHub repository name.',
            optional: false
          },
          {
            name: 'tag_name',
            label: 'Release tag name',
            hint: 'Release tag name or version for the release.',
            optional: false
          }
        ]
      end,

      execute: lambda do |connection, input|
        # https://docs.github.com/en/rest/reference/repos#get-a-release-by-tag-name
        get("repos/#{connection['repo_owner']}/#{input['repo_name']}/releases/tags/#{input['tag_name']}")
          .after_error_response(/.*/) do |_code, body, _, message|
          error("#{message}: #{body}")
        end
          .after_response do |_code, body, _headers|
          output = {}
          output['release_name'] = body['name'].to_s
          output['release_version'] = body['tag_name'].to_s

          if call('valid_yaml', body['body'])
            release_details = workato.parse_yaml(body['body'])
            output['release_manifest'] = release_details['manifest'].to_s || ''
            output['release_package'] = release_details['package'].to_s || ''
            output['release_refs'] = release_details['refs'].to_s || ''
          end

          output
        end
      end, # execute.end

      output_fields: lambda do |object_definitions|
        object_definitions['release_details_output']
      end

    } # get_release.end

  },

  methods: {
    create_next_release: lambda do |connection, input, latest_version|
      latest_version = '0.0.0' if latest_version.blank?

      # https://docs.github.com/en/rest/reference/pulls#list-commits-on-a-pull-request
      commits = get("repos/#{connection['repo_owner']}/#{input['repo_name']}/pulls/#{input['pr_number']}/commits?page=1&per_page=1")
                .after_error_response(/.*/) do |_, body, _, message|
        error("#{message}: #{body}")
      end

      commits.after_response do |_code, body, _headers|
        commit_message = body[0]['commit']['message']
        error("Can't create automatic release, commit message is not valid YAML format.") unless call('valid_yaml',
                                                                                                      commit_message)

        last_version_arr = latest_version.split('.')
        next_version = '0.0.0'

        release_details = workato.parse_yaml(commit_message)

        if release_details.has_key?('fix')
          patch_version = (last_version_arr[2].to_i + 1).to_s
          next_version = "#{last_version_arr[0]}.#{last_version_arr[1]}.#{patch_version}"
          release_log = release_details['fix']

        elsif release_details.has_key?('feat')
          minor_version = (last_version_arr[1].to_i + 1).to_s
          next_version = "#{last_version_arr[0]}.#{minor_version}.0"
          release_log = release_details['feat']

        elsif release_details.has_key?('BREAKING-CHANGE')
          major_version = (last_version_arr[0].to_i + 1).to_s
          next_version =  "#{major_version}.0.0"
          release_log = release_details['BREAKING-CHANGE'] || ''
        end

        release_manifest = release_details['manifest'] if release_details.has_key?('manifest')
        release_package = release_details['package'] if release_details.has_key?('package')
        release_refs = release_details['refs'] if release_details.has_key?('refs')
        continuous_delivery = release_details['CD'] if release_details.has_key?('CD')
        test_folder = release_details['test_folder'] if release_details.has_key?('test_folder')

        # https://docs.github.com/en/rest/reference/repos#create-a-release
        release = post("repos/#{connection['repo_owner']}/#{input['repo_name']}/releases", {
                         tag_name: next_version,
                         name: input['release_name'],
                         body: "#{commit_message}\nPR: #{input['pr_url']}"
                       })
                  .after_error_response(/.*/) do |_, release_body, _, message|
          error("#{message}: #{release_body}")
        end

        release.after_response do |_code, release_body, _headers|
          {
            release_version: next_version,
            release_url: release_body['html_url'],
            release_log: release_log,
            release_manifest: release_manifest,
            release_package: release_package,
            release_refs: release_refs,
            continuous_delivery: continuous_delivery,
            test_folder: test_folder
          }
        end
      end
    end, # create_next_release.end

    valid_yaml: lambda do |log|
      is_valid = true
      if !log.nil? && !log.blank?
        log_list = log.split("\n")
        log_list.each do |line|
          is_valid = false unless line.include?(': ')
        end
      else
        is_valid = false
      end
      is_valid
    end
  }

}
