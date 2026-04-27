# frozen_string_literal: true

class Response < ApplicationRecord
  include ScorableHelper
  include MetricHelper

  belongs_to :response_map, class_name: 'ResponseMap', foreign_key: 'map_id', inverse_of: false
  has_many :scores, class_name: 'Answer', foreign_key: 'response_id', dependent: :destroy, inverse_of: false
  accepts_nested_attributes_for :scores

  alias map response_map
  delegate :response_assignment, :reviewee, :reviewer, to: :map

  # return the questionnaire that belongs to the response
  def questionnaire
    response_assignment.assignment_questionnaires.find_by(used_in_round: self.round).questionnaire
  end

  # returns a string of response name, needed so the front end can tell students which rubric they are filling out
  def rubric_label
    return 'Response' if map.nil?

    if map.respond_to?(:response_map_label)
      label = map.response_map_label
      return label if label.present?
    end

    # response type doesn't exist
    'Unknown Type'
  end

  # Returns true if this response's score differs from peers by more than the assignment notification limit
  def reportable_difference?
    map_class = map.class
    # gets all responses made by a reviewee
    existing_responses = map_class.assessments_for(map.reviewee)

  count = 0
  total_numerator = BigDecimal('0')
  total_denominator = BigDecimal('0')
    # gets the sum total percentage scores of all responses that are not this response
    # (each response can omit questions, so maximum_score may differ and we normalize before averaging)
    existing_responses.each do |response|
      unless id == response.id # the current_response is also in existing_responses array
        count += 1
        # Accumulate raw sums and divide once to minimize rounding error
        total_numerator += BigDecimal(response.aggregate_questionnaire_score.to_s)
        total_denominator += BigDecimal(response.maximum_score.to_s)
      end
    end

    # if this response is the only response by the reviewee, there's no grade conflict
    return false if count.zero?

    # Calculate average of peers by dividing once at the end
    average_score = if total_denominator.zero?
                      0.0
                    else
                      (total_numerator / total_denominator).to_f
                    end

    # This score has already skipped the unfilled scorable item(s)
    # Normalize this response similarly, dividing once
    this_numerator = BigDecimal(aggregate_questionnaire_score.to_s)
    this_denominator = BigDecimal(maximum_score.to_s)
    score = if this_denominator.zero?
              0.0
            else
              (this_numerator / this_denominator).to_f
            end
    questionnaire = questionnaire_by_answer(scores.first)
    assignment = map.assignment
    assignment_questionnaire = AssignmentQuestionnaire.find_by(assignment_id: assignment.id,
                                                               questionnaire_id: questionnaire.id)

    # notification_limit can be specified on 'Rubrics' tab on assignment edit page.
    allowed_difference_percentage = assignment_questionnaire.notification_limit.to_f

    # the range of average_score_on_same_artifact_from_others and score is [0,1]
    # the range of allowed_difference_percentage is [0, 100]
    (average_score - score).abs * 100 > allowed_difference_percentage
  end

  def aggregate_questionnaire_score
    # Quiz questionnaires are graded against their answer key instead of using
    # the standard rubric-style numeric score stored in Answer#answer.
    return aggregate_quiz_questionnaire_score if quiz_questionnaire?

    # only count the scorable items, only when the answer is not nil
    # we accept nil as answer for scorable items, and they will not be counted towards the total score
    scores.sum do |score|
      next 0 if score.answer.nil?

      score.answer * score.item.weight
    end
  end

  # Returns the maximum possible score for this response
  def maximum_score
    # Quiz scores are point-based: each item contributes its weight once if correct.
    return maximum_quiz_score if quiz_questionnaire?

    # only count the scorable questions, only when the answer is not nil (we accept nil as
    # answer for scorable questions, and they will not be counted towards the total score)
    total_weight = 0
    scores.each do |s|
      total_weight += s.item.weight unless s.answer.nil? #|| !s.item.is_a(ScoredItem)?
    end
    total_weight * questionnaire.max_question_score
  end

  private

  def quiz_questionnaire?
    questionnaire&.questionnaire_type == 'QuizQuestionnaire'
  end

  def aggregate_quiz_questionnaire_score
    quiz_scores_by_item.sum do |item_id, item_scores|
      item = quiz_items_by_id[item_id]
      next 0 unless item
      # Skip unanswered quiz items so partially saved drafts do not receive points.
      next 0 unless quiz_answer_present?(item_scores)

      quiz_item_correct?(item, item_scores) ? item.weight.to_i : 0
    end
  end

  def maximum_quiz_score
    quiz_items = if questionnaire.respond_to?(:items)
                   questionnaire.items
                 else
                   quiz_items_by_id.values
                 end

    Array(quiz_items).sum { |item| item.weight.to_i }
  end

  def quiz_scores_by_item
    scores.group_by(&:item_id)
  end

  def quiz_items_by_id
    Item.where(id: quiz_scores_by_item.keys).index_by(&:id)
  end

  def quiz_answer_present?(item_scores)
    item_scores.any? do |score|
      score.answer.present? || score.comments.present?
    end
  end

  def quiz_item_correct?(item, item_scores)
    correct_choices = QuizQuestionChoice.where(question_id: item.id).select(&:iscorrect)
    return false if correct_choices.empty?

    item_type = item.question_type.to_s.downcase

    if item_type.include?('checkbox')
      # Checkbox items are all-or-nothing: the submitted set must exactly match
      # the set of correct choices.
      selected_answers_for_checkbox(item_scores).sort == normalized_correct_choice_texts(correct_choices).sort
    elsif item_type.include?('text')
      # Text answers are matched against any accepted correct answer after
      # normalizing case and whitespace.
      accepted_answers = normalized_correct_choice_texts(correct_choices)
      accepted_answers.include?(normalized_text_response(item_scores.first))
    else
      # Radio / single-choice items may be submitted as a choice id, display text,
      # or position depending on the caller, so we accept any identifier that
      # resolves to the correct option.
      selected_identifiers = selected_identifiers_for_choice_item(item_scores)
      correct_identifiers = correct_choices.each_with_index.flat_map do |choice, index|
        quiz_choice_identifiers(choice, index + 1)
      end

      (selected_identifiers & correct_identifiers).any?
    end
  end

  def selected_answers_for_checkbox(item_scores)
    item_scores.filter_map do |score|
      # Existing checkbox answers use answer == 1 for checked entries, but quiz
      # submissions may also arrive with only comments populated.
      next unless score.answer.nil? || score.answer.to_i == 1

      normalize_quiz_value(score.comments)
    end.uniq
  end

  def normalized_correct_choice_texts(correct_choices)
    correct_choices.filter_map { |choice| normalize_quiz_value(choice.txt) }.uniq
  end

  def normalized_text_response(score)
    return if score.nil?

    normalize_quiz_value(score.comments)
  end

  def selected_identifiers_for_choice_item(item_scores)
    item_scores.flat_map do |score|
      identifiers = []
      identifiers << normalize_quiz_value(score.comments)
      identifiers << normalize_quiz_value(score.answer)
      identifiers
    end.compact.uniq
  end

  def quiz_choice_identifiers(choice, position)
    [
      normalize_quiz_value(choice.id),
      normalize_quiz_value(choice.txt),
      normalize_quiz_value(position)
    ].compact
  end

  def normalize_quiz_value(value)
    # Quiz matching should ignore capitalization and stray whitespace so the
    # answer key can be compared consistently across UI payload shapes.
    normalized_value = value.to_s.squish.downcase
    normalized_value.presence
  end
end
