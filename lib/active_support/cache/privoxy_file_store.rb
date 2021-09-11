module ActiveSupport
  module Cache
    # File store with Privoxy checking.
    class PrivoxyFileStore < FileStore
      def initialize(cache_path, **options)
        super(cache_path, **options)
      end

      def read(name, options = nil)
        puts "CACHE READ:\t#{name}"
        super
      end
    end
  end
end

