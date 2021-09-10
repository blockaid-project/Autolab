class AddRealFilenameToSubmissions < ActiveRecord::Migration[5.2]
  def change
    add_column :submissions, :real_filename, :string

    reversible do |dir|
      dir.up { Submission.update_all('real_filename = filename') }
    end
  end
end
