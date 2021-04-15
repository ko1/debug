module DEBUGGER__
  class SourceRepository
    def initialize
      @files = {} # filename => [src, iseq]
    end

    def add iseq, src
      if src
      else
        begin
          src = File.read(iseq.path)
          @files[iseq.path] = src.lines
        rescue
          src = nil
        end
      end
    end

    def get path
      @files[path]
    end
  end
end
