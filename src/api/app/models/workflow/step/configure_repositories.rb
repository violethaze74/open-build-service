class Workflow::Step::ConfigureRepositories < Workflow::Step
  REQUIRED_KEYS = [:source_project, :repositories].freeze
  REQUIRED_REPOSITORY_KEYS = [:architectures, :name, :target_project, :target_repository].freeze

  validate :validate_step_instructions
  validate :validate_repositories
  validate :validate_architectures

  def call(_options = {})
    return unless valid?

    step_instructions[:repositories].each do |repository_instructions|
      repository = Repository.includes(:architectures).find_or_create_by(name: repository_instructions[:name], project: Project.get_by_name(target_project_name))

      target_repository = Repository.find_by_project_and_name(repository_instructions[:target_project], repository_instructions[:target_repository])
      repository.path_elements.find_or_create_by(link: target_repository)

      repository.repository_architectures.destroy_all

      repository_instructions[:architectures].uniq.each do |architecture_name|
        repository.architectures << @supported_architectures.select { |architecture| architecture.name == architecture_name }
      end
    end
  end

  private

  def validate_step_instructions
    REQUIRED_KEYS.each do |required_key|
      errors.add(:base, "configure_repositories step: The '#{required_key}' key is missing.") unless step_instructions.key?(required_key)
    end
  end

  def validate_repositories
    # FIXME: Change Workflow::Step#initialize `with_indifferent_access` for `deep_symbolize_keys` to consistently work
    #        with symbols, even in nested hashes. This is needed for all workflow steps.
    return if step_instructions.deep_symbolize_keys[:repositories].all? { |repository| repository.keys.sort == REQUIRED_REPOSITORY_KEYS }

    required_repository_keys_sentence ||= REQUIRED_REPOSITORY_KEYS.map { |key| "'#{key}'" }.to_sentence
    errors.add(:base, "configure_repositories step: All repositories must have the #{required_repository_keys_sentence} keys")
  end

  def validate_architectures
    # FIXME: Change Workflow::Step#initialize `with_indifferent_access` for `deep_symbolize_keys` to consistently work
    #        with symbols, even in nested hashes. This is needed for all workflow steps.
    architectures = step_instructions.deep_symbolize_keys[:repositories].map { |repository| repository.fetch(:architectures, []) }.flatten.uniq

    # Store architectures to avoid fetching them again later in #call
    @supported_architectures = Architecture.where(name: architectures).to_a

    return if @supported_architectures.size == architectures.size

    inexistent_architectures = architectures - @supported_architectures.map(&:name)

    return if inexistent_architectures.empty?

    inexistent_architectures_sentence ||= inexistent_architectures.map { |key| "'#{key}'" }.to_sentence
    errors.add(:base, "configure_repositories step: Architectures #{inexistent_architectures_sentence} do not exist")
  end
end
