# -*- coding: utf-8 -*-
class LatexToPdf
  def self.config
    @config||={:command => 'pdflatex', :arguments => ['-halt-on-error'], :parse_twice => false, :parse_runs => 1}
  end

  # Converts a string of LaTeX +code+ into a binary string of PDF.
  #
  # pdflatex is used to convert the file and creates the directory +#{Rails.root}/tmp/rails-latex/+ to store intermediate
  # files.
  #
  # The config argument defaults to LatexToPdf.config but can be overridden using @latex_config.
  #
  # The parse_twice argument and using config[:parse_twice] is deprecated in favor of using config[:parse_runs] instead.
  def self.generate_pdf(code, config, parse_twice=nil)
    config=self.config.merge(config)
    parse_twice=config[:parse_twice] if parse_twice.nil? # deprecated
    parse_runs=[config[:parse_runs], (parse_twice ? 2 : config[:parse_runs])].max
    puts "Running Latex #{parse_runs} times..."
    dir=File.join(Rails.root, 'tmp', 'rails-latex', "#{Process.pid}-#{Thread.current.hash}")
    input_filename='input.tex'
    input=File.join(dir, input_filename)
    FileUtils.mkdir_p(dir)
    # copy any additional supporting files (.cls, .sty, ...)
    supporting = config[:supporting]
    if supporting.kind_of?(String) or supporting.kind_of?(Pathname) or (supporting.kind_of?(Array) and supporting.length > 0)
      FileUtils.cp_r(supporting, dir)
    end
    File.open(input, 'wb') { |io| io.write(code) }
    Process.waitpid(
        fork do
          begin
            Dir.chdir dir
            FileUtils.cp input_filename, "input_orig.tex"
            args=config[:arguments] + %w[-shell-escape -interaction batchmode]+[input_filename]
            original_stdout, original_stderr = $stdout, $stderr
            $stderr = $stdout = File.open("input.log", "a")

            if config[:overfull_vbox]
              buf = File.read(input_filename)
              File.open(input_filename, 'w') do |f|
                f.puts buf.gsub(/\[0pt\]\{\\cell(.*?)(&|\\\\)/m) {
                         t = $2
                         "[0pt]{\\cell#{$1.gsub("\n", ' ')}#{t}"
                       }
              end

              #cmd="#{config[:command]} #{args.join(' ')} | grep 'Overfull \\\\vbox'"
              cmd="#{config[:command]} #{input_filename} | grep 'Overfull \\\\vbox'"
              res=`#{cmd}`.split("\n")
              if res.size > 0
                overfulls = {}
                res.each do |line|
                  line =~ /\((.*?)pt.*?([0-9]+)\z/
                  overfulls[$2.to_i - 1]={'overfull' => $1.to_f.ceil.to_f, 'n_lines' => 0, 'lines' => []}
                end
                expands={}

                cur_mrowexpand = nil
                (buf = File.readlines(input_filename)).each_with_index do |line, index|
                  if line =~ /\\ccell/
                    expands[index] = 0.0
                    cur_mrowexpand = index
                    overfulls.each do |key, val|
                      if val['n_lines'] > val['lines'].size
                        overfulls[key]['lines'] << index
                      end
                    end
                  elsif line =~ /\\multirow\{([0-9]+)\}/
                    next unless overfulls[index]
                    overfulls[index]['n_lines'] = $1.to_i
                    overfulls[index]['first_line'] = cur_mrowexpand
                    overfulls[index]['lines'] << cur_mrowexpand
                  end
                end

                m_overfull = overfulls.map { |key, val| val['overfull']/val['n_lines'] }.max
                m_key, strut = nil, nil
                while m_overfull > 0.0
                  overfulls.each do |key, val|
                    if val['n_lines'] > 0 && val['overfull']/val['n_lines'] == m_overfull
                      m_key = key
                      strut = m_overfull/2.0
                      overfulls[key]['lines'].each do |line|
                        expands[line] = strut.round(2)
                      end
                    end
                  end

                  overfulls.each do |key, val|
                    if key != m_key
                      count = (overfulls[key]['lines'] & overfulls[m_key]['lines']).size
                      overfulls[key]['overfull'] -= strut * 2.0 * count
                    else
                      overfulls[key]['overfull'] = 0.0
                    end
                  end
                  overfulls.each do |key, val|
                    if key != m_key
                      overfulls[key]['lines'] = overfulls[key]['lines'] - overfulls[m_key]['lines']
                      overfulls[key]['n_lines'] = overfulls[key]['lines'].size
                    end
                  end
                  overfulls[m_key]['n_lines'] = 0
                  overfulls[m_key]['lines'] = []

                  m_overfull = overfulls.map { |key, val| val['n_lines'] == 0 ? 0.0 : val['overfull']/val['n_lines'] }.max
                end
                adjusts = {}

                overfulls.each do |key, val|
                  adjusts[key] = expands[val['first_line']]
                end


                File.open(input_filename, 'w') do |f|
                  buf.each_with_index do |line, index|
                    if expands[index] && expands[index] > 0.0
                      f.puts line.gsub(/(\{\\ccell\{.*?%first_cell)/, "\\mrowexpand{#{expands[index]}pt}"+'\1')
                      #f.puts "\\mrowexpand{#{expands[index]}pt}#{line}"
                    elsif adjusts[index]
                      f.puts line.sub(/0pt/, "#{adjusts[index]}pt")
                    else
                      f.puts line
                    end
                  end
                end
              end
            end


            (parse_runs-1).times do
              system config[:command], *args
            end
            exec config[:command], *args
          rescue
            File.open("input.log", 'a') { |io|
              io.write("#{$!.message}:\n#{$!.backtrace.join("\n")}\n")
            }
          ensure
            $stdout, $stderr = original_stdout, original_stderr
            Process.exit! 1
          end
        end

    )
    if File.exist?(pdf_file=input.sub(/\.tex$/, '.pdf'))
      FileUtils.mv(input, File.join(dir, '..', input_filename))
      FileUtils.mv(input.sub(/\.tex$/, '.log'), File.join(dir, '..', 'input.log'))
      result=File.read(pdf_file)
      FileUtils.rm_rf(dir)
    else
      raise "pdflatex failed: See #{input.sub(/\.tex$/, '.log')} for details"
    end
    result
  end

  # Escapes LaTex special characters in text so that they wont be interpreted as LaTex commands.
  #
  # This method will use RedCloth to do the escaping if available.
  def self.escape_latex(text)
    # :stopdoc:
    unless @latex_escaper
      if defined?(RedCloth::Formatters::LATEX)
        class << (@latex_escaper=RedCloth.new(''))
          include RedCloth::Formatters::LATEX
        end
      else
        class << (@latex_escaper=Object.new)
          ESCAPE_RE=/([{}_$&%#])|([\\^~|<>])/
          ESC_MAP={
              '\\' => 'backslash',
              '^' => 'asciicircum',
              '~' => 'asciitilde',
              '|' => 'bar',
              '<' => 'less',
              '>' => 'greater',
          }

          def latex_esc(text) # :nodoc:
            text.gsub(ESCAPE_RE) { |m|
              if $1
                "\\#{m}"
              else
                "\\text#{ESC_MAP[m]}{}"
              end
            }
          end
        end
      end
      # :startdoc:
    end

    @latex_escaper.latex_esc(text.to_s).html_safe
  end

end
