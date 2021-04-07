module DEBUGGER__
  class SourceRepository
    def initialize
      @files = {} # filename => [src, iseq]
    end

    def add iseq, src
      begin
        src = File.read(iseq.path)
      rescue
        src = nil
      end unless src
      @files[iseq.path] = [src, iseq]
    end

    def get path
      @files[path]
    end
  end
end
