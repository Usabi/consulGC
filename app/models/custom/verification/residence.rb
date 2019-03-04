
require_dependency Rails.root.join('app', 'models', 'verification', 'residence').to_s

class Verification::Residence
  include ManageValidations
  attr_accessor :user, :document_number, :document_type, :common_name, :first_surname, :date_of_birth, :postal_code, :geozone_id, :terms_of_service, :official, :mode, :no_resident, :unconfirmed_phone


  # NOTE mode == :manual indicates use of age verification request only
  # NOTE mode == :check indicates no verification needed (user declares residence)

  # Only users of the geozone can interact with these models (see abilities/common)
  # Can also specify the :geozone_id only, in order to manually validate geozone residence

  GEOZONE_PROTECTIONS = [
    # {geozone_id: 1},
    # {geozone_id: 2, model_name: 'Proposal', model_id: 2, action: :vote},
    # {geozone_id: 7}, # Ingenio
    {geozone_id: 4, model_name: 'Budget', model_id: 1, action: :vote} # Arucas
  ].freeze

  validates_presence_of :official, if: Proc.new { |vr| vr.user.residence_requested? && mode == :manual }

  before_validation :retrieve_census_data, if: Proc.new { |vr| mode.nil? }
  before_validation :retrieve_person_data, if: Proc.new { |vr| vr.user.residence_requested? && mode == :manual }

  validate :postal_code_in_gran_canaria, if: Proc.new { |vr| no_resident != "1"}
  validate :residence_in_gran_canaria, if: Proc.new { |vr| mode.nil? }
  validate :allowed_age
  validate :spanish_id, if: Proc.new { |vr| vr.document_type == "1"}

  cancel_validates(:postal_code)
  cancel_validates(:terms_of_service)

  validates :postal_code, presence: true, if: Proc.new { |vr| no_resident != "1" }
  validates :terms_of_service, acceptance: { allow_nil: false }, if: Proc.new { |vr| no_resident != "1"}
  validates :postal_code, length: { is: 5 }, if: Proc.new { |vr| no_resident != "1" }

  def postal_code_in_gran_canaria
    errors.add(:postal_code, I18n.t('verification.residence.new.error_not_allowed_postal_code')) unless valid_postal_code?
  end

  def residence_in_gran_canaria
    return if errors.any?

    unless residency_valid?
      errors.add(:residence_in_gran_canaria, false)
      # Only store one failed attempt between census and person apis
      store_failed_attempt(:census)
      Lock.increase_tries(user)
    end
  end

  def allowed_age
    return if errors[:date_of_birth].any?

    if self.date_of_birth > 16.years.ago
      errors.add(:date_of_birth, I18n.t('verification.residence.new.error_not_allowed_age'))
    end

    if user.residence_requested? && !age_valid?
      errors.add(:date_of_birth, I18n.t('verification.residence.new.error_wrong_age'))
      store_failed_attempt(:person)
      Lock.increase_tries(user) if mode == :manual || residency_valid? # Only increase lock if not already increased by residency
    end
  end

  def spanish_id
    return if errors.any?
    errors.add(:document_number, I18n.t('verification.residence.new.error_invalid_spanish_id')) unless valid_spanish_id?
  end

  def save
    return false unless valid?

    if user.residence_requested? && mode == :manual
      # Updates user data with verified attributes
      attrs = { residence_verified_at: Time.now }
      # TODO Revisar el guardado de geozone
      attrs[:geozone] = geozone unless mode == :manual
      attrs[:gender] = gender unless mode == :manual
      user.update(attrs)
    else
      # Saves user form data from verification request
      user.update(document_number:        document_number,
                  document_type:          document_type,
                  common_name:            common_name,
                  first_surname:          first_surname,
                  geozone_id:             geozone_id,
                  postal_code:            postal_code,
                  date_of_birth:          date_of_birth,
                  no_resident:            no_resident,
                  unconfirmed_phone:      unconfirmed_phone,
                  residence_verified_at:  (Time.now if mode != :manual && !protected_geozones.include?(geozone_id.to_i)),
                  residence_requested_at: (Time.now if mode == :manual || protected_geozones.include?(geozone_id.to_i)))
    end
  end

  def document_number_uniqueness
    errors.add(:document_number, I18n.t('errors.messages.taken')) if User.where(document_number: document_number).where.not(id: user.id).any?
  end

  def store_failed_attempt(klass_name = :census)
    klass = klass_name == :census ? FailedCensusCall : FailedPersonCall
    attrs = {
      user: user,
      document_number: document_number,
      document_type:   document_type,
      date_of_birth:   date_of_birth,
    }
    attrs[:postal_code] = postal_code if klass_name == :census
    if klass_name == :person
      attrs[:common_name] = common_name
      attrs[:first_surname] = first_surname
      attrs[:response] = @person_api_response.error
    end
    klass.create(attrs)
  end

  def geozone
    Geozone.where(census_code: postal_code).first
  end

  def self.geozone_is_protected?(geozone)
    Verification::Residence::GEOZONE_PROTECTIONS.select{|protection| protection[:geozone_id] == geozone.id}.length.positive?
  end

  private

    def retrieve_person_data
      @person_api_response = PersonApi.new.call(document_type, document_number, first_surname, official.username, official.document_number)
    end

    def residency_valid?
      @census_api_response.valid? &&
      @census_api_response.postal_code == postal_code
    end

    def age_valid?
      api_response = @person_api_response || @census_api_response
      api_response.valid? &&
      api_response.date_of_birth == date_of_birth.to_date
    end

    def valid_postal_code?
      postal_code =~ /^35/
    end

    def valid_spanish_id?
      value = document_number.upcase
      return false unless value.match(/^[0-9]{8}[a-z]$/i)
      letters = "TRWAGMYFPDXBNJZSQVHLCKE"
      check = value.slice!(value.length - 1)
      calculated_letter = letters[value.to_i % 23].chr
      return check === calculated_letter
    end

    def protected_geozones
      Verification::Residence::GEOZONE_PROTECTIONS.map {|protection| protection[:geozone_id]}.uniq
    end
end
