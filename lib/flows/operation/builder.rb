require_relative './builder/build_router'

module Flows
  module Operation
    # Flow builder
    class Builder
      attr_reader :steps, :method_source, :deps

      def initialize(steps:, method_source:, deps:)
        @method_source = method_source
        @steps = steps
        @deps = deps

        @step_names = @steps.map { |s| s[:name] }
      end

      def call
        resolve_wiring!
        resolve_bodies!

        nodes = build_nodes
        Flows::Flow.new(start_node: nodes.first.name, nodes: nodes)
      end

      private

      def resolve_wiring! # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        # we have to disable some linters for performance reasons
        # this method can be simplified using `map.with_index`, but while loops is about
        # 2x faster for such cases.
        index = 0

        while index < @steps.length
          current_step = @steps[index]
          next_step_name = nil

          inner_index = index + 1
          while inner_index < @steps.length
            candidate = @steps[inner_index]
            candidate_last_track = candidate[:track_path].last

            if candidate[:track_path] == [] || current_step[:track_path].include?(candidate_last_track)
              next_step_name = candidate[:name]
              break
            end

            inner_index += 1
          end

          current_step[:next_step] = next_step_name || :term

          index += 1
        end
      end

      def resolve_bodies!
        @steps.each do |step|
          step.merge!(
            body: step[:custom_body] || resolve_body_from_source(step[:name])
          )
        end
      end

      def resolve_body_from_source(name)
        return @deps[name] if @deps.key?(name)

        raise(::Flows::Operation::NoStepImplementationError, name) unless @method_source.respond_to?(name)

        @method_source.method(name)
      end

      def build_nodes
        @nodes = @steps.map do |step|
          Flows::Node.new(
            name: step[:name],
            body: build_final_body(step),
            preprocessor: method(:node_preprocessor),
            postprocessor: method(:node_postprocessor),
            router: BuildRouter.call(step[:custom_routes], step[:next_step], @step_names),
            meta: build_meta(step)
          )
        end
      end

      def build_final_body(step)
        case step[:type]
        when :step
          step[:body]
        when :wrapper
          build_wrapper_body(step[:body], step[:block])
        end
      end

      def build_wrapper_body(wrapper, block)
        suboperation_class = Class.new do
          include ::Flows::Operation
        end

        suboperation_class.instance_exec(&block)
        suboperation_class.no_shape

        suboperation = suboperation_class.new(method_source: @method_source, deps: @deps)

        lambda do |**options|
          wrapper.call(**options) { suboperation.call(**options) }
        end
      end

      def build_meta(step)
        {
          type: step[:type],
          name: step[:name],
          track_path: step[:track_path]
        }
      end

      def node_preprocessor(_input, context, _meta)
        context[:data]
      end

      def node_postprocessor(output, context, meta)
        output_data = output.ok? ? output.unwrap : output.error
        context[:data].merge!(output_data)
        context[:last_step] = meta[:name]

        output
      end
    end
  end
end
