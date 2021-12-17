module Capistrano
  class Puma::Monit < Capistrano::Plugin
    def sudo_if_needed(command)
      if fetch(:puma_monit_use_sudo)
        backend.sudo command
      else
        backend.execute command
      end
    end
  end
end
