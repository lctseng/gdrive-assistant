Rake::Task['deploy:assets:precompile'].clear

namespace :deploy do
  namespace :assets do
    desc 'Precompile assets locally and then rsync to web servers'
    task :precompile do
      run_locally do
        with rails_env: :production do
          execute :bundle, 'exec rake assets:precompile'
        end
      end

      on roles(:web), in: :parallel do |server|
        run_locally do
          ['/public/packs/', '/public/assets/'].each do |folder|
            execute :rsync, "-a --delete .#{folder} #{fetch(:ssh_options)[:user]}@#{server.hostname}:#{shared_path}#{folder}" if File.exist? ".#{folder}"
          end
        end
      end

      run_locally do
        execute :rm, '-rf public/assets'
        execute :rm, '-rf public/packs'
      end
    end
  end
end
