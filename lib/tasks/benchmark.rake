require "fileutils"

# This "monkey-patch" for Populator is needed due to a bug in populator which calls
# a non-existent function "sanitize"
# See: https://github.com/ryanb/populator/issues/30
# REMOVE IF THE POPULATOR GEM IS UPDATED!
module Populator
  # Builds multiple Populator::Record instances and saves them to the database
  class Factory
    def rows_sql_arr
      @records.map do |record|
        quoted_attributes = record.attribute_values.map { |v| @model_class.connection.quote(v) }
        "(#{quoted_attributes.join(', ')})"
      end
    end
  end
end

namespace :benchmark do
  COURSE_NAME = "Course"
  COURSE_COUNT = 3
  USER_COUNT = 50
  ASSESSMENT_CATEGORIES = ["Homework", "Lab", "Quiz"]
  ASSESSMENT_COUNT = 6
  PROBLEM_COUNT = 3 
  SUBMISSION_MAX = 3
  PROBLEM_MAX_SCORE = 100.0
  COURSE_START = Time.now - 80.days
  COURSE_END = COURSE_START + 1.years

  AUTOGRADE_CATEGORY_NAME = "CategoryAutograde"
  AUTOGRADE_TEMPLATE_DIR_PATH =
          Rails.root.join("templates", "labtemplate")
  AUTOGRADE_TEMPLATE_CONFIG_PATH =
          Rails.root.join("templates", "AutoPopulated-labtemplate.rb")
  AUTOGRADE_TEMPLATE_NAME = "labtemplate"
  AUTOGRADE_TEMPLATE_DISPLAY_NAME = "Lab Template"
  AUTOGRADE_TEMPLATE_MAX_SCORE = 100.0
  AUTOGRADE_TEMPLATE_PROBLEM_NAME = "autograded"
  AUTOGRADE_TEMPLATE_HANDIN_DIRECTORY = "handin"
  AUTOGRADE_TEMPLATE_HANDIN_FILENAME = "handin.py"

  def load_courses
    (0...COURSE_COUNT).map do |i|
      name = "#{COURSE_NAME}#{i.to_s}"
      Course.create! do |c|
        c.name = name
        c.semester = "SEM"
        c.late_slack = 0
        c.grace_days = 3 
        c.late_penalty = Penalty.new(:value => 5, :kind => "points")
        c.version_penalty = Penalty.new(:value => 5, :kind => "points")
        c.display_name = name
        c.start_date = COURSE_START
        c.end_date = COURSE_END
      end
    end
  end

  def load_assessments course
    course_dir = Rails.root.join("courses", course.name)
    ASSESSMENT_CATEGORIES.each do |cat|

      # start date for this category
      start = COURSE_START + rand(20).day

      ASSESSMENT_COUNT.times do |i|
        course.assessments.create do |a|
          a.category_name = cat
          
          a.visible_at = start 
          a.start_at = start
          a.due_at = start + (5 + rand(11)).days          # 5-15d after start date
          a.end_at = a.due_at + (1 + rand(7)).day   # 1d-1w after the due date
          a.grading_deadline = a.end_at + (1 + rand(7)).day   # 1-7d after submit deadline 

          a.name = "#{cat}#{i.to_s}".downcase
          a.display_name = "#{cat} #{i.to_s}"
          a.handin_directory = "handin"
          a.handin_filename = "handin.c"
          a.course_id = course.id

          a.construct_folder

          # 1-5 day buffer between assessments (in this category)
          start = a.due_at + (1 + rand(5)).day
        end
      end
    end

    # load config files for each assessment now that they've been created
    course.assessments.each do |a|
      a.load_config_file
    end
  end

  def load_problems course
    course.assessments.each do |a|
      PROBLEM_COUNT.times do |i|
        a.problems.create do |p|
          p.name = "problem#{i.to_s}"
          p.max_score = PROBLEM_MAX_SCORE
        end
      end
    end
  end

  def load_all_users
    (0...USER_COUNT).map do |i|
      u = User.new({
        first_name: "User",
        last_name: i.to_s,

        password: '12345678',

        school: "SCS",
        major: "CS",
        year: (1 + rand(4)).to_s,
        email: "user#{i.to_s}@foo.bar".downcase
      })
      u.skip_confirmation!
      u.save!
      u
    end
  end

  def load_users_for_course(students, course)
    i = 0
    students.each do |u|
      CourseUserDatum.create!({
        :course => course,
        :user => u,

        :lecture => "1",
        :section => "None",
        :dropped => false,

        :instructor => false,
        :course_assistant => false,

        :nickname => "user#{i.to_s}_#{course.name}"
      })
      i += 1
    end
  end

  def load_submissions(grader, course)
    grader_cud = CourseUserDatum.create!({
      :user => grader,
      :course => course,

      :lecture => "1",
      :section => "Instructor",
      :dropped => false,

      :instructor => true,
      :course_assistant => true,

      :nickname => "admin_#{course.name}"
    })

    course.course_user_data.find_each do |cud|
      load_submissions_for course, cud, grader_cud
    end
  end

  def load_auds course
    course.assessments.each do |asmt|
      # create all auds
      Rails.logger.info "Creating AUDs for #{asmt.course.name}/#{asmt.name}..."
      asmt.create_AUDs_modulo_callbacks

      # update latest submissions
      Rails.logger.info "Updating AUDs with latest submissions..."
      asmt.update_latest_submissions_modulo_callbacks
    end
  end

  def load_submissions_for(course, cud, grader_cud)
    course_dir = Rails.root.join("courses", course.name)
    user = cud.user

    course.assessments.each do |a|

      sub_count = 1 + rand(SUBMISSION_MAX)
      assessment_dir = File.join(course_dir, a.name)
      assessment_handin_dir = File.join(assessment_dir, a.handin_directory)

      # preprocess valid submission window for assessment
      submission_window = a.end_at - a.start_at

      i = 0
      Submission.populate(sub_count, :per_query => 10000) do |s|
        s.attributes = @default_submission

        s.created_at = s.updated_at = a.end_at - rand(submission_window)
        s.version = i + 1
        s.course_user_datum_id = cud.id
        s.submitted_by_id = cud.id
        s.filename = "#{user.email}_#{i.to_s}_#{a.handin_filename}"
        s.assessment_id = a.id
        s.tweak_id = nil

        # create a fake submission file
        submission_path = File.join(assessment_handin_dir, s.filename)
        FileUtils.mkdir_p(assessment_handin_dir)
        File.open(submission_path,'w+') do |f|
          f.write("int main() {\n  printf(\"Hello Dave!\\n\");\n  return 0;\n}")
        end

        load_scores_for s, grader_cud

        i += 1
      end
    end
  end

  def load_scores_for(submission, grader_cud)
    assessment = Assessment.find(submission.assessment_id)

    assessment.problems.each do |p|
      Score.populate(1, :per_query => 10000) do |score|
        score.attributes = @default_score

        score.score = rand(PROBLEM_MAX_SCORE.to_i).to_f
        score.problem_id = p.id
        score.grader_id = grader_cud.id
        score.released = true
        score.submission_id = submission.id
      end
    end
  end

  def add_assessment_files course
    course_dir = Rails.root.join("courses", course.name)

    course.assessments.each do |a|
      assessment_dir = File.join(course_dir, a.name)
      assessment_handin_dir = File.join(assessment_dir, a.handin_directory)
      assessment_template_path = Rails.root.join("lib", "__defaultAssessment.rb")
      assessment_template = nil

      File.open(assessment_template_path) do |f|
        assessment_template = f.read
      end

      problem_hashes = ""
      PROBLEM_COUNT.times do |i|
        problem_hashes << "{ 'name' => 'problem#{i}', 'max_score' => '#{PROBLEM_MAX_SCORE + 0.0}', 'description' => ''},"
      end
      problem_string = "@problems = [#{problem_hashes}]"

      config_file_string = assessment_template.gsub("##NAME_CAMEL##", a.name.downcase.capitalize)
                                              .gsub("##NAME_LOWER##", a.name)
                                              .gsub("##PROBLEMS##", problem_string)

      config_file_path = File.join(assessment_dir, "#{a.name}.rb")
      File.open(config_file_path, "w") do |f|
        f.write config_file_string
      end

      # TODO (tabraham): figure this out
      # Assessment.reload_config_file(course, a.name)
    end
  end

  def load_autograde_assessment course

    course_dir = Rails.root.join("courses", course.name)

    # Create assessment
    asmt = course.assessments.create! do |a|
      a.category_name = AUTOGRADE_CATEGORY_NAME
      
      a.visible_at = COURSE_START
      a.start_at = COURSE_START
      a.due_at = COURSE_START + (5 + rand(11)).days
      a.end_at = a.due_at + (1 + rand(7)).day
      a.grading_deadline = a.end_at + (1 + rand(7)).day

      a.name = AUTOGRADE_TEMPLATE_NAME
      a.display_name = AUTOGRADE_TEMPLATE_DISPLAY_NAME
      a.handin_directory = AUTOGRADE_TEMPLATE_HANDIN_DIRECTORY
      a.handin_filename = AUTOGRADE_TEMPLATE_HANDIN_FILENAME
      a.course_id = course.id

      FileUtils.mkdir_p(File.join(course_dir, a.name, a.handin_directory))
    end

    # Load autograding properties
    Autograder.create! do |autograder|
      autograder.assessment_id = asmt.id
      autograder.autograde_image = "autograding_image"
      autograder.autograde_timeout = 180
      autograder.release_score = true
    end

    # Load problem "autograded"
    asmt.problems.create(name: AUTOGRADE_TEMPLATE_PROBLEM_NAME,
                         max_score: AUTOGRADE_TEMPLATE_MAX_SCORE)

    # Copy assessment folder
    FileUtils.cp_r(AUTOGRADE_TEMPLATE_DIR_PATH, course_dir)

    # Copy assessment config
    assessmentConfig_dir = Rails.root.join("assessmentConfig")
    FileUtils.cp(AUTOGRADE_TEMPLATE_CONFIG_PATH, assessmentConfig_dir)

    # Reload config file
    asmt.load_config_file
  end

  task :load => :environment do |t, args|
    require "populator" 
  
    abort("Only use this task in production or test.") unless Rails.env == "production"

    # seed rng
    srand 1234

    # to get defaults
    unwanted = lambda { |key, _| key == "created_at" || key == "updated_at" || key == "id" }
    @default_submission = Submission.new.attributes.delete_if &unwanted
    @default_score = Score.new.attributes.delete_if &unwanted
    @default_user = User.new.attributes.delete_if &unwanted

    # puts "Creating users"
    users = load_all_users

    puts "Creating courses" 
    load_courses

    grader = User.new({
      first_name: "Course",
      last_name: "Assistant",

      password: '12345678',

      school: "SCS",
      major: "CS",
      year: "4",
      email: "admin@foo.bar",
    })
    grader.skip_confirmation!
    grader.save!

    Course.all.each do |course|
      puts "=== Course #{course.id.to_s} ==="

      puts "Creating Assessments"
      load_assessments course

      puts "Creating Problems"
      load_problems course

      puts "Loading users for courses"
      load_users_for_course(users, course)

      puts "Fast-creating Submissions and Scores (might take a while)"
      load_submissions(grader, course)
    end

    # delete grader's AUDs (create_AUDs_module_callbacks insists on creating them)
    AssessmentUserDatum.delete_all()

    Course.all.each do |course|
      puts "Fast-creating AUDs"
      load_auds course

      puts "Creating configuration files"
      add_assessment_files course

      # puts "Creating Autograde Assessment"
      # load_autograde_assessment course

      course.reload_config_file
    end

    puts "Population Successful"
  end
end

