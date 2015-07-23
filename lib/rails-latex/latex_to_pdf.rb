# -*- coding: utf-8 -*-
class LatexToPdf
  def self.config
    @config||={:command => 'pdflatex', :arguments => ['-halt-on-error'], :parse_twice => false, :parse_runs => 1,
               :overfull_vbox => true}
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
    input_filename=input.tex
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
            if config[:overfull_vbox]
              cmd="#{config[:command]} #{input_filename} | grep 'Overfull \\\\vbox'"
              res=`#{cmd}`.split("\n")
              overfulls = []
              res.each do |line|
                line =~ /\((.*?)pt.*?([0-9]+)\z/
                overfulls << [$2.to_i - 1, $1.to_f.ceil]
              end
              buf = File.readlines(input_filename)
              val=0
              File.open(input_filename, 'w') do |f|
                buf.each_with_index do |line, index|
                  if overfulls.size > 0 && index == overfulls.first.first
                    new_val=overfulls.shift.last
                    val = new_val if new_val > val
                  end
                  if val > 0 && line =~ /\\\\/
                    f.puts line.sub(/\\\\[^\[]/, "\\\\\\[#{val}pt]")
                    val=0
                  else
                    f.puts line
                  end
                end
              end
            end

            original_stdout, original_stderr = $stdout, $stderr
            $stderr = $stdout = File.open("input.log", "a")
            args=config[:arguments] + %w[-shell-escape -interaction batchmode input.tex]
            (parse_runs-1).times do
              system config[:command], '-draftmode', *args
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
        end)
    if File.exist?(pdf_file=input.sub(/\.tex$/, '.pdf'))
      FileUtils.mv(input, File.join(dir, '..', 'input.tex'))
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
