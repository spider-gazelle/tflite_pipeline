require "../configuration"

class TensorflowLite::Pipeline::Configuration::Pipeline
  include JSON::Serializable

  property name : String
  property description : String?

  # do we want the steps all complete and then return a combined result
  # or do we want to process each step as fast as possible with out of order results
  #
  # NOTE:: use promise any to get result -> as we need to block tasker pipelines so we don't needlessly
  # process input images
  property async : Bool = false

  property input : Input
  property output : Array(Model)
end
