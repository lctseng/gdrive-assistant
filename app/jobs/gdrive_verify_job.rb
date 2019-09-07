# frozen_string_literal: true

require 'open3'
require 'fileutils'

class GdriveVerifyJob < ApplicationJob
  REDIS_FIELDS = %w[
    id
    state
    download_count
    comment
    src_folder_id
    src_folder_path
    dst_folder_id
    dst_folder_path
    diff_json
  ].freeze

  sidekiq_options retry: 0
  sidekiq_retries_exhausted do |msg, _ex|
    Rails.logger.warn "Failed #{msg['class']} with #{msg['args']}: #{msg['error_message']}"
    id = msg['args'][0]
    rkey = redis_key(id)
    redis.hset(rkey, 'state', 'error')
    redis.hset(rkey, 'comment', msg['error_message'])
    # Clean up
    if cleanup_on_error?
      %w[src_folder_path dst_folder_path].each do |field|
        cleanup_path(redis.hget(rkey, field))
      end
    end
  end

  def self.cleanup_path(path)
    return unless path.present?

    Rails.logger.info "Cleaning #{path}"
    FileUtils.remove_entry_secure(path)
  end

  def self.clear_redis
    redis.keys('verify-*').each do |key|
      redis.del(key)
    end
  end

  def self.cache_downloaded_files?
    Rails.env.development?
  end

  def self.cleanup_on_error?
    true
  end

  def self.extract_folder_id_from_url(url)
    url = url.strip
    res = url.match(/^http.*id=([a-zA-Z0-9\-_]+)/)
    return res[1] if res && res[1]

    res = url.match(%r{^http.*/folders/([a-zA-Z0-9\-_]+)})
    return res[1] if res && res[1]

    sanity_check(url)

    url
  end

  def self.gdrive_global_options
    ["-c #{File.join(Rails.root, 'config', 'gdrive')}"]
  end

  def self.gdrive_ready?
    run_gdrive_command('list')
  end

  def self.run_gdrive_command(*args, &block)
    exec_path = File.join(PLATFORM_BIN_PATH, 'gdrive')
    cmd_line = ([exec_path] + gdrive_global_options + args).join(' ')
    Rails.logger.info cmd_line
    res = false
    Open3.popen3(cmd_line) do |_stdin, stdout, stderr, wait_thr|
      _stdin.close
      loop do
        break if stdout.eof? || stderr.eof?

        rs = IO.select([stdout, stderr])[0]
        next unless r = rs[0]

        line = r.gets
        if r.fileno == stdout.fileno
          # stdout
          Rails.logger.info line
          if line
            res = line.match(/^Downloading (.*) ->/)
            block.call(res[1]) if res && block
          else
            stdout.close
          end
        else
          # stderr
          Rails.logger.error line
        end
      end
      res = wait_thr.value.success?
      if res
        Rails.logger.info 'Download successfully'
      else
        Rails.logger.info 'Download failed'
      end
    end
    res
  end

  def self.sanity_check(folder_id)
    raise "Malformed Folder ID: #{folder_id}" unless folder_id.match?(/^[a-zA-Z0-9\-_]+$/)
  end

  def self.find_first_valid_folder(path)
    Dir.foreach(path) do |item|
      next if (item == '.') || (item == '..')

      return File.join(path, item)
    end
    path
  end

  def self.register(src_folder_url, dst_folder_url, perform_now = false)
    src_folder_id = extract_folder_id_from_url(src_folder_url)
    dst_folder_id = extract_folder_id_from_url(dst_folder_url)
    id = SecureRandom.uuid
    init_redis_record(id, src_folder_id, dst_folder_id)
    if perform_now
      new.perform(id, src_folder_id, dst_folder_id)
    else
      perform_async(id, src_folder_id, dst_folder_id)
    end
    [true, id]
  rescue StandardError => e
    msg = "Failed to register job: #{e.message}"
    Rails.logger.error(msg)
    [false, msg]
  end

  def self.init_redis_record(id, src_folder_id, dst_folder_id)
    rkey = redis_key(id)
    redis.hset(rkey, 'id', id)
    redis.hset(rkey, 'state', 'init')
    redis.hset(rkey, 'download_count', 0)
    redis.hset(rkey, 'comment', '')
    redis.hset(rkey, 'diff_json', '{}')
    redis.hset(rkey, 'src_folder_id', src_folder_id)
    redis.hset(rkey, 'dst_folder_id', dst_folder_id)
    redis.expire(rkey, 300)
  end

  def self.get_job_state(job_id)
    res = {}
    REDIS_FIELDS.each do |field|
      res[field] = redis.hget(redis_key(job_id), field)
    end
    res
  end

  def self.redis
    Redis.current
  end

  def self.redis_key(id)
    "verify-#{id}"
  end

  def redis
    self.class.redis
  end

  def expire_time
    1800
  end

  def reset_expire
    redis.expire(redis_key, expire_time)
  end

  def redis_key
    self.class.redis_key(@id)
  end

  def download_folder(folder_id)
    self.class.sanity_check(folder_id)
    cache_folder = File.join(Rails.root, 'tmp', 'download_cache', folder_id)
    base_folder = self.class.cache_downloaded_files? ? cache_folder : Dir.mktmpdir
    if self.class.cache_downloaded_files? && File.directory?(cache_folder)
      Rails.logger.info "Cache enabled and folder exists, skipping #{folder_id}"
      return cache_folder
    end
    Rails.logger.info("Downloading to #{base_folder}")
    self.class.run_gdrive_command('download', '--recursive', '--skip', '--path', base_folder, folder_id) do |filename|
      redis.hincrby(redis_key, 'download_count', 1)
      redis.hset(redis_key, 'comment', "上一個項目: #{filename}")
      reset_expire
    end
    base_folder
  end

  def perform(id, src_folder_id, dst_folder_id)
    @id = id
    @src_folder_id = src_folder_id
    @dst_folder_id = dst_folder_id
    Rails.logger.info('Downloading src folder')
    redis.hset(redis_key, 'state', 'download_src')
    @src_folder_path = download_folder(@src_folder_id)
    redis.hset(redis_key, 'src_folder_path', @src_folder_path)
    redis.hset(redis_key, 'state', 'download_dst')
    Rails.logger.info('Downloading dst folder')
    @dst_folder_path = download_folder(@dst_folder_id)
    redis.hset(redis_key, 'dst_folder_path', @dst_folder_path)
    redis.hset(redis_key, 'state', 'compare')
    compare_folder
  end

  def compare_folder
    res = {
      missing: [],
      mismatch: []
    }
    compare_folder_recursive(
      res,
      self.class.find_first_valid_folder(@src_folder_path),
      self.class.find_first_valid_folder(@dst_folder_path)
    )
    if res[:missing].empty? && res[:mismatch].empty?
      Rails.logger.info("Compare success: #{@id}")
      redis.hset(redis_key, 'state', 'success')
    else
      Rails.logger.error("Compare failed: #{@id}")
      Rails.logger.error("List of missing files: #{res[:missing].inspect}")
      Rails.logger.error("List of mismatch files: #{res[:mismatch].inspect}")
      redis.hset(redis_key, 'state', 'failed')
      redis.hset(redis_key, 'diff_json', res.to_json)
    end
    unless self.class.cache_downloaded_files?
      self.class.cleanup_path(@src_folder_path)
      self.class.cleanup_path(@dst_folder_path)
    end
  end

  # Make sure all files in src folder are presented in dst folder
  def compare_folder_recursive(result, src_folder, dst_folder, current_path = '')
    Rails.logger.info "Comparing folder #{src_folder} <=> #{dst_folder}"
    if src_folder != dst_folder
      Dir.foreach(src_folder) do |item|
        next if (item == '.') || (item == '..')

        src_path = File.join(src_folder, item)
        dst_path = File.join(dst_folder, item)
        if File.exist?(dst_path) && File.file?(src_path) == File.file?(dst_path)
          if File.directory? dst_path
            # Recursive call
            compare_folder_recursive(result, src_path, dst_path, File.join(current_path, item))
          else
            # Compare file content
            unless FileUtils.compare_file(src_path, dst_path)
              filename = File.join(current_path, item)
              Rails.logger.error "File differ: #{filename}"
              result[:mismatch] << filename
            end
          end
        else
          filename = File.join(current_path, item)
          Rails.logger.error "File not found: #{filename}"
          result[:missing] << filename
        end
      end
    else
      Rails.logger.warn 'Same folder path, skip comparing'
    end
  end
end
