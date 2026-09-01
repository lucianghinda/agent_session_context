# frozen_string_literal: true

module Agent
  module SessionContext
    module ImmutableValue
      CYCLIC_ERROR = "cyclic arrays and hashes are not supported"
      private_constant :CYCLIC_ERROR

      class Copier
        def initialize
          @copies = {}.compare_by_identity
          @active = {}.compare_by_identity
        end

        def copy(value)
          case value
          when String
            String.new(value).freeze
          when Array
            copy_array(value)
          when Hash
            copy_hash(value)
          else
            value
          end
        end

        private

        def copy_array(array)
          detect_cycle!(array)
          return @copies.fetch(array) if @copies.key?(array)

          duplicate = []
          @copies[array] = duplicate
          @active[array] = true
          array.each { |entry| duplicate << copy(entry) }
          duplicate.freeze
        ensure
          @active.delete(array)
        end

        def copy_hash(hash)
          detect_cycle!(hash)
          return @copies.fetch(hash) if @copies.key?(hash)

          duplicate = {}
          @copies[hash] = duplicate
          @active[hash] = true
          hash.each do |key, value|
            duplicate[copy(key)] = copy(value)
          end
          duplicate.freeze
        ensure
          @active.delete(hash)
        end

        def detect_cycle!(value)
          raise ArgumentError, CYCLIC_ERROR if @active[value]
        end
      end
      private_constant :Copier

      module_function

      def copy(value)
        Copier.new.copy(value)
      end
    end
  end
end
