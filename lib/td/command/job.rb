
module TreasureData
module Command

  # TODO
  JOB_WAIT_MAX_RETRY_COUNT_ON_NETWORK_ERROR = 10

  PRIORITY_FORMAT_MAP = {
    -2 => 'VERY LOW',
    -1 => 'LOW',
    0 => 'NORMAL',
    1 => 'HIGH',
    2 => 'VERY HIGH',
  }

  PRIORITY_PARSE_MAP = {
    /\Avery[ _\-]?low\z/i => -2,
    /\A-2\z/ => -2,
    /\Alow\z/i => -1,
    /\A-1\z/ => -1,
    /\Anorm(?:al)?\z/i => 0,
    /\A[\-\+]?0\z/ => 0,
    /\Ahigh\z/i => 1,
    /\A[\+]?1\z/ => 1,
    /\Avery[ _\-]?high\z/i => 2,
    /\A[\+]?2\z/ => 2,
  }

  def job_list(op)
    page = 0
    skip = 0
    status = nil
    slower_than = nil

    op.on('-p', '--page PAGE', 'skip N pages', Integer) {|i|
      page = i
    }
    op.on('-s', '--skip N', 'skip N jobs', Integer) {|i|
      skip = i
    }
    op.on('-R', '--running', 'show only running jobs', TrueClass) {|b|
      status = 'running'
    }
    op.on('-S', '--success', 'show only succeeded jobs', TrueClass) {|b|
      status = 'success'
    }
    op.on('-E', '--error', 'show only failed jobs', TrueClass) {|b|
      status = 'error'
    }
    op.on('--slow [SECONDS]', 'show slow queries (default threshold: 3600 seconds)', Integer) {|i|
      slower_than = i || 3600
    }
    set_render_format_option(op)

    max = op.cmd_parse

    max = (max || 20).to_i

    client = get_client

    if page
      skip += max * page
    end

    conditions = nil
    if slower_than
      conditions = {:slower_than => slower_than}
    end

    jobs = client.jobs(skip, skip + max - 1, status, conditions)

    rows = []
    jobs.each {|job|
      start = job.start_at
      elapsed = Command.humanize_elapsed_time(start, job.end_at)
      cpu_time = Command.humanize_time(job.cpu_time, true)
      priority = job_priority_name_of(job.priority)
      query = (op.render_format == 'table' || op.render_format.nil? ? job.query.to_s[0,50] + " ..." : job.query)
      rows << {
        :JobID => job.job_id,
        :Database => job.db_name,
        :Status => job.status,
        :Type => job.type,
        :Query => query,
        :Start => (start ? start.localtime : ''),
        :Elapsed => elapsed.rjust(11),
        :CPUTime => cpu_time.rjust(17),
        :ResultSize => (job.result_size ? Command.humanize_bytesize(job.result_size, 2) : ""),
        :Priority => priority,
        :Result => job.result_url
      }
    }

    puts cmd_render_table(rows,
      :fields => [:JobID, :Status, :Start, :Elapsed, :CPUTime, :ResultSize, :Priority, :Result, :Type, :Database, :Query],
      :max_width => 1000,
      :render_format => op.render_format
    )
  end

  def job_show(op)
    verbose = nil
    wait = false
    output = nil
    format = nil
    render_opts = {:header => false}
    limit = nil
    exclude = false

    op.on('-v', '--verbose', 'show logs', TrueClass) {|b|
      verbose = b
    }
    op.on('-w', '--wait', 'wait for finishing the job', TrueClass) {|b|
      wait = b
    }
    op.on('-G', '--vertical', 'use vertical table to show results', TrueClass) {|b|
      render_opts[:vertical] = b
    }
    op.on('-o', '--output PATH', 'write result to the file') {|s|
      unless Dir.exist?(File.dirname(s))
        s = File.expand_path(s)
      end
      output = s
      format = 'tsv' if format.nil?
    }
    op.on('-f', '--format FORMAT', 'format of the result to write to the file (tsv, csv, json, msgpack, and msgpack.gz)') {|s|
      unless ['tsv', 'csv', 'json', 'msgpack', 'msgpack.gz'].include?(s)
        raise "Unknown format #{s.dump}. Supported formats are: tsv, csv, json, msgpack, and msgpack.gz"
      end
      format = s
    }
    op.on('-l', '--limit ROWS', 'limit the number of result rows shown when not outputting to file') {|s|
      unless s.to_i > 0
        raise "Invalid limit number. Must be a positive integer"
      end
      limit = s.to_i
    }
    op.on('-c', '--column-header', 'output of the columns\' header when the schema is available',
                                   '  for the table (only applies to tsv and csv formats)', TrueClass) {|b|
      render_opts[:header] = b;
    }
    op.on('-x', '--exclude', 'do not automatically retrieve the job result', TrueClass) {|b|
      exclude = b
    }

    job_id = op.cmd_parse

    # parameter concurrency validation

    if output.nil? && format
      unless ['tsv', 'csv', 'json'].include?(format)
        raise ParameterConfigurationError,
              "Supported formats are only tsv, csv and json without -o / --output option"
      end
    end

    if render_opts[:header]
      unless ['tsv', 'csv'].include?(format)
        raise ParameterConfigurationError,
              "Option -c / --column-header is only supported with tsv and csv formats"
      end
    end

    if !output.nil? && !limit.nil?
      raise ParameterConfigurationError,
            "Option -l / --limit is only valid when not outputting to file (no -o / --output option provided)"
    end

    client = get_client

    job = client.job(job_id)

    puts "JobID       : #{job.job_id}"
    #puts "URL         : #{job.url}"
    puts "Status      : #{job.status}"
    puts "Type        : #{job.type}"
    puts "Database    : #{job.db_name}"
    # exclude some fields from bulk_import_perform type jobs
    if [:hive, :pig, :impala, :presto].include?(job.type)
      puts "Priority    : #{job_priority_name_of(job.priority)}"
      puts "Retry limit : #{job.retry_limit}"
      puts "Output      : #{job.result_url}"
      puts "Query       : #{job.query}"
    elsif job.type == :bulk_import_perform
      puts "Destination : #{job.query}"
    end
    # if the job is done and is of type hive, show the Map-Reduce cumulated CPU time
    if job.finished?
      if [:hive].include?(job.type)
        puts "CPU time    : #{Command.humanize_time(job.cpu_time, true)}"
      end
      if [:hive, :pig, :impala, :presto].include?(job.type)
        puts "Result size : #{Command.humanize_bytesize(job.result_size, 2)}"
      end
    end

    # up to 7 retries with exponential (base 2) back-off starting at 'retry_delay'
    retry_delay = 5
    max_cumul_retry_delay = 200
    cumul_retry_delay = 0

    if wait && !job.finished?
      wait_job(job)
      if [:hive, :pig, :impala, :presto].include?(job.type) && !exclude
        puts "Result      :"

        begin
          show_result(job, output, limit, format, render_opts)
        rescue TreasureData::NotFoundError => e
          # Got 404 because result not found.
        rescue TreasureData::APIError, # HTTP status code 500 or more
               Errno::ECONNREFUSED, Errno::ECONNRESET, Timeout::Error, EOFError,
               OpenSSL::SSL::SSLError, SocketError => e
          # don't retry on 300 and 400 errors
          if e.class == TreasureData::APIError && e.message !~ /^5\d\d:\s+/
            raise e
          end
          if cumul_retry_delay > max_cumul_retry_delay
            raise e
          end
          $stderr.puts "Error #{e.class}: #{e.message}. Retrying after #{retry_delay} seconds..."
          sleep retry_delay
          cumul_retry_delay += retry_delay
          retry_delay *= 2
          retry
        end
      end

    else
      if [:hive, :pig, :impala, :presto].include?(job.type) && !exclude && job.finished?
        puts "Result      :"
        begin
          show_result(job, output, limit, format, render_opts)
        rescue TreasureData::NotFoundError => e
          # Got 404 because result not found.
        rescue TreasureData::APIError,
               Errno::ECONNREFUSED, Errno::ECONNRESET, Timeout::Error, EOFError,
               OpenSSL::SSL::SSLError, SocketError => e
          # don't retry on 300 and 400 errors
          if e.class == TreasureData::APIError && e.message !~ /^5\d\d:\s+/
            raise e
          end
          if cumul_retry_delay > max_cumul_retry_delay
            raise e
          end
          $stderr.puts "Error #{e.class}: #{e.message}. Retrying after #{retry_delay} seconds..."
          sleep retry_delay
          cumul_retry_delay += retry_delay
          retry_delay *= 2
          retry
        end
      end

      if verbose
        if !job.debug['cmdout'].nil?
          puts ""
          puts "Output:"
          job.debug['cmdout'].to_s.split("\n").each {|line|
            puts "  " + line
          }
        end
        if !job.debug['stderr'].nil?
          puts ""
          puts "Details:"
          job.debug['stderr'].to_s.split("\n").each {|line|
            puts "  " + line
          }
        end
      end
    end

    puts "\rUse '-v' option to show detailed messages." + " " * 20 unless verbose
  end

  def job_status(op)
    job_id = op.cmd_parse
    client = get_client

    puts client.job_status(job_id)
  end

  def job_kill(op)
    job_id = op.cmd_parse

    client = get_client

    former_status = client.kill(job_id)
    if TreasureData::Job::FINISHED_STATUS.include?(former_status)
      $stderr.puts "Job #{job_id} is already finished (#{former_status})"
      exit 0
    end

    if former_status == TreasureData::Job::STATUS_RUNNING
      $stderr.puts "Job #{job_id} is killed."
    else
      $stderr.puts "Job #{job_id} is canceled."
    end
  end

  private
  def wait_job(job, first_call = false)
    $stderr.puts "queued..."

    cmdout_lines = 0
    stderr_lines = 0
    max_error_counts = JOB_WAIT_MAX_RETRY_COUNT_ON_NETWORK_ERROR

    while first_call || !job.finished?
      first_call = false
      begin
        sleep 2
        job.update_status!
      rescue Timeout::Error, SystemCallError, EOFError, SocketError
        if max_error_counts <= 0
          raise
        end
        max_error_counts -= 1
        retry
      end

      cmdout = job.debug['cmdout'].to_s.split("\n")[cmdout_lines..-1] || []
      stderr = job.debug['stderr'].to_s.split("\n")[stderr_lines..-1] || []
      (cmdout + stderr).each {|line|
        puts "  "+line
      }
      cmdout_lines += cmdout.size
      stderr_lines += stderr.size
    end
  end

  def show_result(job, output, limit, format, render_opts={})
    if output
      write_result(job, output, limit, format, render_opts)
      puts "\rwritten to #{output} in #{format} format" + " " * 50
    else
      # every format that is allowed on stdout
      render_result(job, limit, format, render_opts)
    end
  end

  def write_result(job, output, limit, format, render_opts={})

    # the next 3 formats allow writing to both a file and stdout

    case format
    when 'json'
      require 'yajl'
      open_file(output, "w") {|f|
        f.write "["
        n_rows = 0
        unless output.nil?
          indicator = Command::SizeBasedDownloadProgressIndicator.new(
            "NOTE: the job result is being written to #{output} in json format",
            job.result_size, 0.1, 1)
        end
        job.result_each_with_compr_size {|row, compr_size|
          indicator.update(compr_size) unless output.nil?
          f.write ",\n" if n_rows > 0
          f.write Yajl.dump(row)
          n_rows += 1
          break if output.nil? and !limit.nil? and n_rows == limit
        }
        f.write "]"
        indicator.finish unless output.nil?
      }
      puts if output.nil?

    when 'csv'
      require 'yajl'
      require 'csv'

      open_file(output, "w") {|f|
        writer = CSV.new(f)
        # output headers
        if render_opts[:header] && job.hive_result_schema
          writer << job.hive_result_schema.map {|name, type|
            name
          }
        end
        # output data
        n_rows = 0
        unless output.nil?
          indicator = Command::SizeBasedDownloadProgressIndicator.new(
            "NOTE: the job result is being written to #{output} in csv format",
            job.result_size, 0.1, 1)
        end
        job.result_each_with_compr_size {|row, compr_size|
          # TODO limit the # of columns
          writer << row.map {|col|
            dump_column(col)
          }
          n_rows += 1
          if n_rows % 100 == 0 # flush every 100 recods
            writer.flush
            indicator.update(compr_size) unless output.nil?
          end
          break if output.nil? and !limit.nil? and n_rows == limit
        }
        indicator.finish unless output.nil?
      }

    when 'tsv'
      require 'yajl'

      open_file(output, "w") {|f|
        # output headers
        if render_opts[:header] && job.hive_result_schema
          job.hive_result_schema.each {|name,type|
            f.write name + "\t"
          }
          f.write "\n"
        end
        # output data
        n_rows = 0
        unless output.nil?
          indicator = Command::SizeBasedDownloadProgressIndicator.new(
            "NOTE: the job result is being written to #{output} in tsv format",
            job.result_size, 0.1, 1)
        end
        job.result_each_with_compr_size {|row, compr_size|
          f.write row.map {|col| dump_column(col)}.join("\t") + "\n"
          n_rows += 1
          if n_rows % 100 == 0
            f.flush # flush every 100 recods
            indicator.update(compr_size) unless output.nil?
          end
          break if output.nil? and !limit.nil? and n_rows == limit
        }
        indicator.finish unless output.nil?
      }

    # these last 2 formats are only valid if writing the result to file through the -o/--output option.

    when 'msgpack'
      if output.nil?
        raise ParameterConfigurationError,
              "Format 'msgpack' does not support writing to stdout"
      end
      open_file(output, "wb") {|f|
        indicator = Command::SizeBasedDownloadProgressIndicator.new(
          "NOTE: the job result is being written to #{output} in msgpack format",
          job.result_size, 0.1, 1)
        job.result_format('msgpack', f) {|compr_size|
          indicator.update(compr_size)
        }
        indicator.finish
      }

    when 'msgpack.gz'
      if output.nil?
        raise ParameterConfigurationError,
              "Format 'msgpack' does not support writing to stdout"
      end
      open_file(output, "wb") {|f|
        indicator = Command::SizeBasedDownloadProgressIndicator.new(
          "NOTE: the job result is being written to #{output} in msgpack.gz format",
          job.result_size, 0.1, 1)
        job.result_format('msgpack.gz', f) {|compr_size|
          indicator.update(compr_size)
        }
        indicator.finish
      }

    else
      raise "Unknown format #{format.inspect}"
    end
  end

  def open_file(output, mode)
    f = nil
    if output.nil?
      yield STDOUT
    else
      f = File.open(output, mode)
      yield f
    end
  ensure
    if f
      f.close unless f.closed?
    end
  end

  def render_result(job, limit, format=nil, render_opts={})
    require 'yajl'

    if format.nil?
      # display result in tabular format
      rows = []
      n_rows = 0

      indicator = Command::SizeBasedDownloadProgressIndicator.new(
        "WARNING: the job result is being downloaded...", job.result_size, 0.1, 1)
      job.result_each_with_compr_size {|row, compr_size|
        indicator.update(compr_size)
        rows << row.map {|v|
          dump_column_safe_utf8(v)
        }
        n_rows += 1
        break if !limit.nil? and n_rows == limit
      }
      print " " * 100, "\r" # make sure the previous WARNING is cleared over

      render_opts[:max_width] = 10000
      if job.hive_result_schema
        render_opts[:change_fields] = job.hive_result_schema.map { |name,type| name }
      end

      print "\r" + " " * 50
      puts "\r" + cmd_render_table(rows, render_opts)
    else
      # display result in any of: json, csv, tsv.
      # msgpack and mspgpack.gz are not supported for stdout output
      write_result(job, nil, limit, format, render_opts)
    end
  end

  def dump_column(v)
    s = v.is_a?(String) ? v.to_s : Yajl.dump(v)
    # CAUTION: msgpack-ruby populates byte sequences as Encoding.default_internal which should be BINARY
    s = s.force_encoding('BINARY') if s.respond_to?(:encode)
    s
  end

  def dump_column_safe_utf8(v)
    s = dump_column(v)
    # Here does UTF-8 -> UTF-16LE -> UTF8 conversion:
    #   a) to make sure the string doesn't include invalid byte sequence
    #   b) to display multi-byte characters as it is
    #   c) encoding from UTF-8 to UTF-8 doesn't check/replace invalid chars
    #   d) UTF-16LE was slightly faster than UTF-16BE, UTF-32LE or UTF-32BE
    s = s.encode('UTF-16LE', 'UTF-8', :invalid=>:replace, :undef=>:replace).encode!('UTF-8') if s.respond_to?(:encode)
    s
  end

  def job_priority_name_of(id)
    PRIORITY_FORMAT_MAP[id] || 'NORMAL'
  end

  def job_priority_id_of(name)
    PRIORITY_PARSE_MAP.each_pair {|pattern,id|
      return id if pattern.match(name)
    }
    return nil
  end

end # module Command
end # module TrasureData

