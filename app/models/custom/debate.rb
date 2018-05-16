require_dependency Rails.root.join('app', 'models', 'debate').to_s

class Debate
  validates :area, presence: true

  def votable_by?(user)
    return false unless user
    return false unless user.level_two_or_three_verified?
    total_votes <= 100 ||
      !user.unverified? ||
      Setting['max_ratio_anon_votes_on_debates'].to_i == 100 ||
      anonymous_votes_ratio < Setting['max_ratio_anon_votes_on_debates'].to_i ||
      user.voted_for?(self)
  end

  protected
  def sanitize_description; end

end
