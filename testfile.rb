{
  title: 'Docebo',
  
  connection: {
    fields: [
      {
        name: 'subdomain'
      },
      {
        name: 'client_id'
      },
      {
        name: 'client_secret',
        control_type: 'password'
      }
    ],
    authorization: {
      type: 'oauth2',

      client_id: lambda do |connection|
        connection['client_id']
      end,

      client_secret: lambda do |connection|
        connection['client_secret']
      end,
      
      authorization_url: lambda do |connection|
        "https://#{connection['subdomain']}.docebosaas.com/oauth2/authorize?scope=api&response_type=code"
      end,
      
      token_url: lambda do |connection|
        "https://#{connection['subdomain']}.docebosaas.com/oauth2/token"
      end,
      
      acquire: lambda do |connection, auth_code|
        params = {
          "client_id" => connection['client_id'],
          "client_secret" => connection['client_secret'],
          "code" => auth_code,
          "grant_type" => "authorization_code",
          "redirect_uri" => "https://www.workato.com/oauth/callback"
        }
        response = post("https://#{connection['subdomain']}.docebosaas.com/oauth2/token").payload(params).request_format_www_form_urlencoded
        [
          {
      	    access_token: response["access_token"],
      	    refresh_token: response["refresh_token"],
      	  }
        ]
      end,
      
      refresh: lambda do |connection, refresh_token|
        params = {
          "client_id" => connection['client_id'],
          "client_secret" => connection['client_secret'],
          "refresh_token" => refresh_token,
          "grant_type" => "refresh_token"
        }
        response = post("https://#{connection['subdomain']}.docebosaas.com/oauth2/token").payload(params).request_format_www_form_urlencoded
        [
          {
      	    access_token: response["access_token"],
      	    refresh_token: response["refresh_token"],
      	  }
        ]
      end,

      apply: lambda do |connection, access_token|
        headers("Authorization": "Bearer #{access_token}")
      end,
      
      refresh_on: [ 401, /Unauthorized/ ]

    },
    
    base_uri: lambda do |connection|
      "https://#{connection['subdomain']}.docebosaas.com/"
    end
    
  },
  
  test: ->(connection) { 
     get("/learn/v1/courses") 
  },

  methods: {
    ##############################################################
    # Helper methods                                             #
    ##############################################################
    # This method is for Custom action
    make_schema_builder_fields_sticky: lambda do |schema|
      schema.map do |field|
        if field['properties'].present?
          field['properties'] = call('make_schema_builder_fields_sticky',
                                     field['properties'])
        end
        field['sticky'] = true

        field
      end
    end,

    # Formats input/output schema to replace any special characters in name,
    # without changing other attributes (method required for custom action)
    format_schema: lambda do |input|
      input&.map do |field|
        if (props = field[:properties])
          field[:properties] = call('format_schema', props)
        elsif (props = field['properties'])
          field['properties'] = call('format_schema', props)
        end
        if (name = field[:name])
          field[:label] = field[:label].presence || name.labelize
          field[:name] = name
                         .gsub(/\W/) { |spl_chr| "__#{spl_chr.encode_hex}__" }
        elsif (name = field['name'])
          field['label'] = field['label'].presence || name.labelize
          field['name'] = name
                          .gsub(/\W/) { |spl_chr| "__#{spl_chr.encode_hex}__" }
        end

        field
      end
    end,

    # Formats payload to inject any special characters that previously removed
    format_payload: lambda do |payload|
      if payload.is_a?(Array)
        payload.map do |array_value|
          call('format_payload', array_value)
        end
      elsif payload.is_a?(Hash)
        payload.each_with_object({}) do |(key, value), hash|
          key = key.gsub(/__\w+__/) do |string|
            string.gsub(/__/, '').decode_hex.as_utf8
          end
          if value.is_a?(Array) || value.is_a?(Hash)
            value = call('format_payload', value)
          end
          hash[key] = value
        end
      end
    end,

    # Formats response to replace any special characters with valid strings
    # (method required for custom action)
    format_response: lambda do |response|
      response = response&.compact unless response.is_a?(String) || response
      if response.is_a?(Array)
        response.map do |array_value|
          call('format_response', array_value)
        end
      elsif response.is_a?(Hash)
        response.each_with_object({}) do |(key, value), hash|
          key = key.gsub(/\W/) { |spl_chr| "__#{spl_chr.encode_hex}__" }
          if value.is_a?(Array) || value.is_a?(Hash)
            value = call('format_response', value)
          end
          hash[key] = value
        end
      else
        response
      end
    end
  },

  object_definitions: {
    custom_action_input: {
      fields: lambda do |_connection, config_fields|
        verb = config_fields['verb']
        input_schema = parse_json(config_fields.dig('input', 'schema') || '[]')
        data_props =
          input_schema.map do |field|
            if config_fields['request_type'] == 'multipart' &&
               field['binary_content'] == 'true'
              field['type'] = 'object'
              field['properties'] = [
                { name: 'file_content', optional: false },
                {
                  name: 'content_type',
                  default: 'text/plain',
                  sticky: true
                },
                { name: 'original_filename', sticky: true }
              ]
            end
            field
          end
        data_props = call('make_schema_builder_fields_sticky', data_props)
        input_data =
          if input_schema.present?
            if input_schema.dig(0, 'type') == 'array' &&
               input_schema.dig(0, 'details', 'fake_array')
              {
                name: 'data',
                type: 'array',
                of: 'object',
                properties: data_props.dig(0, 'properties')
              }
            else
              { name: 'data', type: 'object', properties: data_props }
            end
          end

        [
          {
            name: 'path',
            hint: 'Base URI is <b>' \
            '{APP_BASE_URI}' \
            '</b> - path will be appended to this URI. Use absolute URI to ' \
            'override this base URI.',
            optional: false
          },
          if %w[post put patch].include?(verb)
            {
              name: 'request_type',
              default: 'json',
              sticky: true,
              extends_schema: true,
              control_type: 'select',
              pick_list: [
                ['JSON request body', 'json'],
                ['URL encoded form', 'url_encoded_form'],
                ['Mutipart form', 'multipart'],
                ['Raw request body', 'raw']
              ]
            }
          end,
          {
            name: 'response_type',
            default: 'json',
            sticky: false,
            extends_schema: true,
            control_type: 'select',
            pick_list: [['JSON response', 'json'], ['Raw response', 'raw']]
          },
          if %w[get options delete].include?(verb)
            {
              name: 'input',
              label: 'Request URL parameters',
              sticky: true,
              add_field_label: 'Add URL parameter',
              control_type: 'form-schema-builder',
              type: 'object',
              properties: [
                {
                  name: 'schema',
                  sticky: input_schema.blank?,
                  extends_schema: true
                },
                input_data
              ].compact
            }
          else
            {
              name: 'input',
              label: 'Request body parameters',
              sticky: true,
              type: 'object',
              properties:
                if config_fields['request_type'] == 'raw'
                  [{
                    name: 'data',
                    sticky: true,
                    control_type: 'text-area',
                    type: 'string'
                  }]
                else
                  [
                    {
                      name: 'schema',
                      sticky: input_schema.blank?,
                      extends_schema: true,
                      schema_neutral: true,
                      control_type: 'schema-designer',
                      sample_data_type: 'json_input',
                      custom_properties:
                        if config_fields['request_type'] == 'multipart'
                          [{
                            name: 'binary_content',
                            label: 'File attachment',
                            default: false,
                            optional: true,
                            sticky: true,
                            render_input: 'boolean_conversion',
                            parse_output: 'boolean_conversion',
                            control_type: 'checkbox',
                            type: 'boolean'
                          }]
                        end
                    },
                    input_data
                  ].compact
                end
            }
          end,
          {
            name: 'request_headers',
            sticky: false,
            extends_schema: true,
            control_type: 'key_value',
            empty_list_title: 'Does this HTTP request require headers?',
            empty_list_text: 'Refer to the API documentation and add ' \
            'required headers to this HTTP request',
            item_label: 'Header',
            type: 'array',
            of: 'object',
            properties: [{ name: 'key' }, { name: 'value' }]
          },
          unless config_fields['response_type'] == 'raw'
            {
              name: 'output',
              label: 'Response body',
              sticky: true,
              extends_schema: true,
              schema_neutral: true,
              control_type: 'schema-designer',
              sample_data_type: 'json_input'
            }
          end,
          {
            name: 'response_headers',
            sticky: false,
            extends_schema: true,
            schema_neutral: true,
            control_type: 'schema-designer',
            sample_data_type: 'json_input'
          }
        ].compact
      end
    },

    custom_action_output: {
      fields: lambda do |_connection, config_fields|
        response_body = { name: 'body' }

        [
          if config_fields['response_type'] == 'raw'
            response_body
          elsif (output = config_fields['output'])
            output_schema = call('format_schema', parse_json(output))
            if output_schema.dig(0, 'type') == 'array' &&
               output_schema.dig(0, 'details', 'fake_array')
              response_body[:type] = 'array'
              response_body[:properties] = output_schema.dig(0, 'properties')
            else
              response_body[:type] = 'object'
              response_body[:properties] = output_schema
            end

            response_body
          end,
          if (headers = config_fields['response_headers'])
            header_props = parse_json(headers)&.map do |field|
              if field[:name].present?
                field[:name] = field[:name].gsub(/\W/, '_').downcase
              elsif field['name'].present?
                field['name'] = field['name'].gsub(/\W/, '_').downcase
              end
              field
            end

            { name: 'headers', type: 'object', properties: header_props }
          end
        ].compact
      end
    }
  },

  actions: {
    
    batch_import_users: {
      
         input_fields: lambda do |_object_definitions|
           [
             {
               "name": "items",
               "type": "array",
               "of": "object",
               "label": "Items",
               "properties": [
                 {
                   "control_type": "text",
                   "label": "Username",
                   "type": "string",
                   "name": "username",
                   "details": {
                     "real_name": "username"
                   }
                 },
                 {
                   "control_type": "number",
                   "label": "User ID",
                   "parse_output": "integer_conversion",
                   "render_input": "integer_conversion",
                   "type": "number",
                   "name": "user_id",
                   "details": {
                     "real_name": "user_id"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "New username",
                   "type": "string",
                   "name": "new_username",
                   "details": {
                     "real_name": "new_username"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Firstname",
                   "type": "string",
                   "name": "firstname",
                   "details": {
                     "real_name": "firstname"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Lastname",
                   "type": "string",
                   "name": "lastname",
                   "details": {
                     "real_name": "lastname"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Password",
                   "type": "string",
                   "name": "password",
                   "details": {
                     "real_name": "password"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Password hash",
                   "type": "string",
                   "name": "password_hash",
                   "details": {
                     "real_name": "password_hash"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Email",
                   "type": "string",
                   "name": "email",
                   "details": {
                     "real_name": "email"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Timezone",
                   "type": "string",
                   "name": "timezone",
                   "details": {
                     "real_name": "timezone"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Date format",
                   "type": "string",
                   "name": "date_format",
                   "details": {
                     "real_name": "date_format"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Country",
                   "type": "string",
                   "name": "country",
                   "details": {
                     "real_name": "country"
                   }
                 },
                 {
                   "control_type": "checkbox",
                   "label": "Active",
                   "render_input": "boolean_conversion",
                   "parse_output": "boolean_conversion",
                   "toggle_hint": "Select from option list",
                   "toggle_field": {
                     "label": "Active",
                     "control_type": "text",
                     "toggle_hint": "Use custom value",
                     "type": "boolean",
                     "name": "active"
                   },
                   "type": "boolean",
                   "name": "active",
                   "details": {
                     "real_name": "active"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Expiration date",
                   "type": "string",
                   "name": "expiration_date",
                   "details": {
                     "real_name": "expiration_date"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Manager xxx",
                   "type": "string",
                   "name": "manager_xxx",
                   "details": {
                     "real_name": "manager_xxx"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Level",
                   "type": "string",
                   "name": "level",
                   "details": {
                     "real_name": "level"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Profile",
                   "type": "string",
                   "name": "profile",
                   "details": {
                     "real_name": "profile"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Language",
                   "type": "string",
                   "name": "language",
                   "details": {
                     "real_name": "language"
                   }
                 },
                 {
                   "control_type": "checkbox",
                   "label": "Is manager",
                   "render_input": "boolean_conversion",
                   "parse_output": "boolean_conversion",
                   "toggle_hint": "Select from option list",
                   "toggle_field": {
                     "label": "Is manager",
                     "control_type": "text",
                     "toggle_hint": "Use custom value",
                     "type": "boolean",
                     "name": "is_manager"
                   },
                   "type": "boolean",
                   "name": "is_manager",
                   "details": {
                     "real_name": "is_manager"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Branch name path",
                   "type": "string",
                   "name": "branch_name_path",
                   "details": {
                     "real_name": "branch_name_path"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Branch code path",
                   "type": "string",
                   "name": "branch_code_path",
                   "details": {
                     "real_name": "branch_code_path"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Branch name",
                   "type": "string",
                   "name": "branch_name",
                   "details": {
                     "real_name": "branch_name"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Branch code",
                   "type": "string",
                   "name": "branch_code",
                   "details": {
                     "real_name": "branch_code"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Field xxx",
                   "type": "string",
                   "name": "field_xxx",
                   "details": {
                     "real_name": "field_xxx"
                   }
                 }
               ],
               "details": {
                 "real_name": "items"
               }
             },
             {
               "properties": [
                 {
                   "control_type": "checkbox",
                   "label": "Change user password",
                   "render_input": "boolean_conversion",
                   "parse_output": "boolean_conversion",
                   "toggle_hint": "Select from option list",
                   "toggle_field": {
                     "label": "Change user password",
                     "control_type": "text",
                     "toggle_hint": "Use custom value",
                     "type": "boolean",
                     "name": "change_user_password"
                   },
                   "type": "boolean",
                   "name": "change_user_password",
                   "details": {
                     "real_name": "change_user_password"
                   }
                 },
                 {
                   "control_type": "checkbox",
                   "label": "Update user info",
                   "render_input": "boolean_conversion",
                   "parse_output": "boolean_conversion",
                   "toggle_hint": "Select from option list",
                   "toggle_field": {
                     "label": "Update user info",
                     "control_type": "text",
                     "toggle_hint": "Use custom value",
                     "type": "boolean",
                     "name": "update_user_info"
                   },
                   "type": "boolean",
                   "name": "update_user_info",
                   "details": {
                     "real_name": "update_user_info"
                   }
                 },
                 {
                   "control_type": "checkbox",
                   "label": "Ignore password change for existing users",
                   "render_input": "boolean_conversion",
                   "parse_output": "boolean_conversion",
                   "toggle_hint": "Select from option list",
                   "toggle_field": {
                     "label": "Ignore password change for existing users",
                     "control_type": "text",
                     "toggle_hint": "Use custom value",
                     "type": "boolean",
                     "name": "ignore_password_change_for_existing_users"
                   },
                   "type": "boolean",
                   "name": "ignore_password_change_for_existing_users",
                   "details": {
                     "real_name": "ignore_password_change_for_existing_users"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Power user option",
                   "type": "string",
                   "name": "powerUser_option",
                   "details": {
                     "real_name": "powerUser_option"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Destination branch",
                   "type": "string",
                   "name": "destination_branch",
                   "details": {
                     "real_name": "destination_branch"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Branch option",
                   "type": "string",
                   "name": "branch_option",
                   "details": {
                     "real_name": "branch_option"
                   }
                 },
                 {
                   "control_type": "checkbox",
                   "label": "Force create branches",
                   "render_input": "boolean_conversion",
                   "parse_output": "boolean_conversion",
                   "toggle_hint": "Select from option list",
                   "toggle_field": {
                     "label": "Force create branches",
                     "control_type": "text",
                     "toggle_hint": "Use custom value",
                     "type": "boolean",
                     "name": "force_create_branches"
                   },
                   "type": "boolean",
                   "name": "force_create_branches",
                   "details": {
                     "real_name": "force_create_branches"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "User destination branch action",
                   "type": "string",
                   "name": "user_destination_branch_action",
                   "details": {
                     "real_name": "user_destination_branch_action"
                   }
                 },
                 {
                   "control_type": "checkbox",
                   "label": "Send notification email",
                   "render_input": "boolean_conversion",
                   "parse_output": "boolean_conversion",
                   "toggle_hint": "Select from option list",
                   "toggle_field": {
                     "label": "Send notification email",
                     "control_type": "text",
                     "toggle_hint": "Use custom value",
                     "type": "boolean",
                     "name": "send_notification_email"
                   },
                   "type": "boolean",
                   "name": "send_notification_email",
                   "details": {
                     "real_name": "send_notification_email"
                   }
                 },
                 {
                   "control_type": "text",
                   "label": "Multi profiles mode",
                   "type": "string",
                   "name": "multi_profiles_mode",
                   "details": {
                     "real_name": "multi_profiles_mode"
                   }
                 }
               ],
               "label": "Options",
               "type": "object",
               "name": "options",
               "details": {
                 "real_name": "options"
               }
             }
           ]
         end,
      
      execute: lambda do |_connection, input|
        post("/manage/v1/user/batch", input)
      end,
      
      output_fields: lambda do |_object_definitions|
        [
          {
            "name": "data",
            "type": "array",
            "of": "object",
            "label": "Data",
            "properties": [
              {
                "control_type": "number",
                "label": "Row index",
                "parse_output": "integer_conversion",
                "render_input": "integer_conversion",
                "type": "number",
                "name": "row_index",
                "details": {
                  "real_name": "row_index"
                }
              },
              {
                "control_type": "text",
                "label": "Success",
                "parse_output": "boolean_conversion",
                "render_input": "boolean_conversion",
                "toggle_hint": "Select from option list",
                "toggle_field": {
                  "label": "Success",
                  "control_type": "text",
                  "toggle_hint": "Use custom value",
                  "type": "boolean",
                  "name": "success"
                },
                "type": "boolean",
                "name": "success",
                "details": {
                  "real_name": "success"
                }
              },
              {
                "control_type": "text",
                "label": "Message",
                "type": "string",
                "name": "message",
                "details": {
                  "real_name": "message"
                }
              },
              {
                "properties": [
                  {
                    "control_type": "number",
                    "label": "User ID",
                    "parse_output": "integer_conversion",
                    "render_input": "integer_conversion",
                    "type": "number",
                    "name": "user_id",
                    "details": {
                      "real_name": "user_id"
                    }
                  },
                  {
                    "control_type": "text",
                    "label": "Username",
                    "type": "string",
                    "name": "username",
                    "details": {
                      "real_name": "username"
                    }
                  },
                  {
                    "control_type": "text",
                    "label": "Error",
                    "type": "string",
                    "name": "error",
                    "details": {
                      "real_name": "error"
                    }
                  }
                ],
                "label": "Output",
                "type": "object",
                "name": "output",
                "details": {
                  "real_name": "output"
                }
              }
            ],
            "details": {
              "real_name": "data"
            }
          }
        ]
      end
    },
    
    
    custom_action: {
      subtitle: 'Build your own {APP} action with a HTTP request',

      description: lambda do |object_value, _object_label|
        "<span class='provider'>" \
        "#{object_value[:action_name] || 'Custom action'}</span> in " \
        "<span class='provider'>{APP}</span>"
      end,

      help: {
        body: 'Build your own {APP} action with a HTTP request. ' \
        'The request will be authorized with your {APP} connection.',
        learn_more_url: '{APP_API_URL}',
        learn_more_text: '{APP} API documentation'
      },

      config_fields: [
        {
          name: 'action_name',
          hint: "Give this action you're building a descriptive name, e.g. " \
          'create record, get record',
          default: 'Custom action',
          optional: false,
          schema_neutral: true
        },
        {
          name: 'verb',
          label: 'Method',
          hint: 'Select HTTP method of the request',
          optional: false,
          control_type: 'select',
          pick_list: %w[get post put patch options delete]
            .map { |verb| [verb.upcase, verb] }
        }
      ],

      input_fields: lambda do |object_definition|
        object_definition['custom_action_input']
      end,

      execute: lambda do |_connection, input|
        verb = input['verb']
        if %w[get post put patch options delete].exclude?(verb)
          error("#{verb.upcase} not supported")
        end
        path = input['path']
        data = input.dig('input', 'data') || {}
        if input['request_type'] == 'multipart'
          data = data.each_with_object({}) do |(key, val), hash|
            hash[key] = if val.is_a?(Hash)
                          [val[:file_content],
                           val[:content_type],
                           val[:original_filename]]
                        else
                          val
                        end
          end
        end
        request_headers = input['request_headers']
          &.each_with_object({}) do |item, hash|
          hash[item['key']] = item['value']
        end || {}
        request = case verb
                  when 'get'
                    get(path, data)
                  when 'post'
                    if input['request_type'] == 'raw'
                      post(path).request_body(data)
                    else
                      post(path, data)
                    end
                  when 'put'
                    if input['request_type'] == 'raw'
                      put(path).request_body(data)
                    else
                      put(path, data)
                    end
                  when 'patch'
                    if input['request_type'] == 'raw'
                      patch(path).request_body(data)
                    else
                      patch(path, data)
                    end
                  when 'options'
                    options(path, data)
                  when 'delete'
                    delete(path, data)
                  end.headers(request_headers)
        request = case input['request_type']
                  when 'url_encoded_form'
                    request.request_format_www_form_urlencoded
                  when 'multipart'
                    request.request_format_multipart_form
                  else
                    request
                  end
        response =
          if input['response_type'] == 'raw'
            request.response_format_raw
          else
            request
          end
          .after_error_response(/.*/) do |code, body, headers, message|
            error({ code: code, message: message, body: body, headers: headers }
              .to_json)
          end

        response.after_response do |_code, res_body, res_headers|
          {
            body: res_body ? call('format_response', res_body) : nil,
            headers: res_headers
          }
        end
      end,

      output_fields: lambda do |object_definition|
        object_definition['custom_action_output']
      end
    }
  }
}
