# frozen_string_literal: true

Rake::Task['sidekiq:monit:config'].clear_actions
namespace :sidekiq do
  namespace :monit do
    # Don't automatically update it..
    # task :add_default_hooks do
    #   before 'deploy:updating',  'sidekiq:monit:unmonitor'
    #   after  'deploy:published', 'sidekiq:monit:monitor'
    # end

    desc 'Config Sidekiq monit-service'
    task :config do
      on roles(fetch(:sidekiq_roles)) do |role|
        @role = role
        upload_sidekiq_template 'sidekiq_monit', "#{fetch(:tmp_dir)}/monit.conf", @role

        mv_command = "cp #{fetch(:tmp_dir)}/monit.conf #{fetch(:sidekiq_monit_conf_dir)}/#{fetch(:sidekiq_monit_conf_file)}"
        execute mv_command

        print("*** Please reload 'monit' if needed. ***")
        # sudo_if_needed "#{fetch(:monit_bin)} reload"
      end
    end
  end
end
