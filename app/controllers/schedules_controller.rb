class SchedulesController < ApplicationController


	############################################################################
	# Initialization
	############################################################################


	# Filters
	before_filter :require_login
	before_filter :save_entries, :only => [:edit]
	before_filter :find_optional_project, :only => [:report, :details]
	before_filter :find_project, :only => [:estimate]
	before_filter :save_default, :only => [:default]
	
	# Included helpers
	include SchedulesHelper
	helper :sort
	include SortHelper


	############################################################################
	# Class methods
	############################################################################
	
	
	# Return a list of the projects the user has permission to view schedules in
	def self.visible_projects
		Project.find(:all, :conditions => Project.allowed_to_condition(User.current, :view_schedules))
	end
	
	
	# Return a list of the users in the given projects which have permission to view schedules
	def self.visible_users(members)		
		members.select {|m| m.role.allowed_to?(:view_schedules)}.collect {|m| m.user}.uniq.sort
	end


	############################################################################
	# Public actions
	############################################################################
	
	
	# Given a specific month, show the projects and users that the current user is
	# allowed to see and provide links to edit based on specific dates, projects or
	# users.
	def index
		# Determine if we're looking at a specific user or project
		@project = Project.find(params[:project_id]) if params[:project_id]
		@user = User.find(params[:user_id]) if params[:user_id] 
	
		# Initialize the calendar helper
		@date = Date.parse(params[:date]) if params[:date]
		@date ||= Date.civil(params[:year].to_i, params[:month].to_i, params[:day].to_i) if params[:year] && params[:month] && params[:day]
		@date ||= Date.today
		@calendar = Redmine::Helpers::Calendar.new(Date.civil(@date.year, @date.month, @date.day), current_language, :week)
		
		# Retrieve the associated schedule_entries
		@projects = visible_projects.sort
		@projects = @projects & @user.projects unless @user.nil?
		@projects = @projects & [@project] unless @project.nil?
		@users = visible_users(@projects.collect(&:members).flatten.uniq) if @project.nil?
		@users = visible_users(@project.members) unless @project.nil?
		@users = [@user] unless @user.nil?
		
		if @projects.size > 0 && @users.size > 0
			@entries = get_entries
			@availabilities = get_availabilities
			render :action => 'index', :layout => false if request.xhr?
			render :action => 'index' unless request.xhr?
		else
			deny_access
		end
	end
	
	
	# View schedule for the current user
	def my
		params[:user_id] = User.current.id
		index
	end
	
	
	# Show the current user's default availability and, if instructed, change it
	def default
		
		@user = User.current
		
		# Determine the user's current availability default
		@schedule_default = ScheduleDefault.find_by_user_id(@user)
		@schedule_default ||= ScheduleDefault.new 
		@schedule_default.weekday_hours ||= [0,0,0,0,0,0,0] 
		@schedule_default.user_id = @user
			
		@calendar = Redmine::Helpers::Calendar.new(Date.today, current_language, :week)
	end
	

	# Given a specific day, user or project, show the complementary rows and columns
	# and provide input fields for each coordinate cell. If the current user doesn't
	# have access to a row or column it shouldn't display. Likewise, if the current
	# user can only view a cell, display it as disabled.
	def edit
		# Get specified user or project, if any
		@project = Project.find(params[:project_id]) if params[:project_id]
		@projects = [@project] if params[:project_id]
		@user = User.find(params[:user_id]) if params[:user_id]
		@users = [@user] if params[:user_id]
		
		# Must edit a user or a project
		if @project.nil? && @user.nil?
			render_404
			return
		end
		
		# If no user or project was specified, determine them
		@projects = @user.nil? ? visible_projects : @user.projects if @projects.nil?
		@projects = @projects & visible_projects
		if @user.nil?
			@users = visible_users(@projects.collect{|p| p.members }.flatten)
		end
		
		# If we couldn't find any users or projects, then we don't have access
		if @projects.size == 0 || @users.size == 0
			deny_access
			return
		end
		
		# Sort the projects and users
		@projects = @projects.sort
		@users = @users.sort
		
		# Parse the given date
		@date = Date.parse(params[:date]) if params[:date]
		@date ||= Date.civil(params[:year].to_i, params[:month].to_i, params[:day].to_i) if params[:year] && params[:month] && params[:day]
		@date ||= Date.today
		@date = Date.civil(@date.year, @date.month, @date.day - @date.wday) if @user || @project
		
		# Initialize the necessary helpers
		@calendar = Redmine::Helpers::Calendar.new(@date, current_language, :week) if @user.nil? || @project.nil?
		@calendar = Redmine::Helpers::Calendar.new(@date, current_language) unless @user.nil? || @project.nil?

		# Get the current entries
		@entries = get_entries
		@closed_entries = get_closed_entries
		
		# Render the page
		render :layout => !request.xhr?
	end
	
	# Given a version, we want to estimate when it can be completed. Do generate
	# this date, we need open issues to have time estimates and for assigned
	# individuals to have scheduled time.
	#
	# This function makes a number of assumtions when generating the estimate that,
	# in practice, aren't generally true. For example, issues may have multiple
	# users addressing them or may require validation before the next step begins.
	# Issues often have undeclared dependancies that aren't initially clear. These
	# may affect when the version is completed.
	#
	# Note that this method talks about issue parents and children. These refer to
	# to issues that are blocked or preceded by others.
	def estimate
		
		# Obtain all open issues for the given version
		@open_issues = @version.fixed_issues.collect { |issue| issue unless issue.closed? }.compact.index_by { |issue| issue.id }

		# Confirm that all issues have estimates, are assigned and only have parents in this version
		raise l(:error_schedules_estimate_unestimated_issues) if !@open_issues.collect { |issue_id, issue| issue if issue.estimated_hours.nil? && (issue.done_ratio < 100) }.compact.empty?
		raise l(:error_schedules_estimate_unassigned_issues) if !@open_issues.collect { |issue_id, issue| issue if issue.assigned_to.nil? && (issue.done_ratio < 100) }.compact.empty?
		raise l(:error_schedules_estimate_open_interversion_parents) if !@open_issues.collect do |issue_id, issue|
			issue.relations.collect do |relation|
				Issue.find(
					:first,
					:include => :status,
					:conditions => ["#{Issue.table_name}.id=? AND #{IssueStatus.table_name}.is_closed=? AND (#{Issue.table_name}.fixed_version_id<>? OR #{Issue.table_name}.fixed_version_id IS NULL)", relation.issue_from_id, false, @version.id]
				) if (relation.issue_to_id == issue.id) && schedule_relation?(relation)
			end
		end.flatten.compact.empty?

		# Obtain all assignees 
		assignees = @open_issues.collect { |issue_id, issue| issue.assigned_to }.uniq
		raise l(:error_schedules_estimate_project_unscheduled) if assignees.empty?
		@entries = ScheduleEntry.find(
			:all,
			:conditions => sprintf("user_id IN (%s) AND date > NOW() AND project_id = %s", assignees.collect {|user| user.id }.join(','), @version.project.id),
			:order => ["date"]
		).group_by{ |entry| entry.user_id }
		@entries.each { |user_id, user_entries| @entries[user_id] = user_entries.index_by { |entry| entry.date } }
		raise l(:error_schedules_estimate_project_unscheduled) if @entries.empty? || !@version.project.module_enabled?('schedule_module')
		
		# Build issue precedence hierarchy
		floating_issues = Set.new	# Issues with no children or parents
		surfaced_issues = Set.new	# Issues with children, but no parents 
		buried_issues = Set.new		# Issues with parents
		@open_issues.each do |issue_id, issue|
			issue.start_date = nil
			issue.due_date = nil
			issue.relations.each do |relation|
				if (relation.issue_to_id == issue.id) && schedule_relation?(relation)
					if @open_issues.has_key?(relation.issue_from_id)
						buried_issues.add(issue)
						surfaced_issues.add(@open_issues[relation.issue_from_id])
					end
				end
			end
		end
		surfaced_issues.subtract(buried_issues)
		floating_issues = Set.new(@open_issues.values).subtract(surfaced_issues).subtract(buried_issues)

		# Surface issues and schedule them
		while !surfaced_issues.empty?
			buried_issues.subtract(surfaced_issues)
			
			next_layer = Set.new	# Issues surfaced by scheduling the current layer
			surfaced_issues.each do |surfaced_issue|
				
				# Schedule the surfaced issue
				schedule_issue(surfaced_issue)
				
				# Move child issues to appropriate buckets
				surfaced_issue.relations.each do |relation|
					if (relation.issue_from_id == surfaced_issue.id) && schedule_relation?(relation) && @open_issues.include?(relation.issue_to_id) && buried_issues.include?(@open_issues[relation.issue_to_id])
						considered_issue = @open_issues[relation.issue_to_id]
						
						# If the issue is blocked by buried relations, then it stays buried
						if !considered_issue.relations.collect { |r| true if (r.issue_to_id == considered_issue.id) && schedule_relation?(r) && buried_issues.include?(@open_issues[r.issue_from_id]) }.compact.empty?
							
						# If the issue blocks buried relations, then it surfaces
						elsif !considered_issue.relations.collect { |r| true if (r.issue_from_id == considered_issue.id) && schedule_relation?(r) && buried_issues.include?(@open_issues[r.issue_to_id]) }.compact.empty?
							next_layer.add(considered_issue)
						
						# If the issue has no buried relations, then it floats
						else
							buried_issues.delete(considered_issue)
							floating_issues.add(considered_issue)
						end
					end
				end
			end
			surfaced_issues = next_layer
		end

		# Schedule remaining floating issues by priority
		floating_issues.sort { |a,b| b.priority <=> a.priority }.each do |floating_issue|
			schedule_issue(floating_issue)
		end
		
		# That's your milestone due date
		@version.effective_date = @open_issues.collect { |issue_id, issue| issue }.max { |a,b| a.due_date <=> b.due_date }.due_date
		
		# Save the issues and milestone date if requested.
		if params[:confirm_estimate]
			@open_issues.each { |issue_id, issue| issue.save }
			@version.save
			flash[:notice] = l(:label_schedules_estimate_updated)
			redirect_to({:controller => 'versions', :action => 'show', :id => @version.id})
		end
		
	rescue Exception => e
		flash[:error] = e.message
		redirect_to({:controller => 'versions', :action => 'show', :id => @version.id})
	end
	
##----------------------------------------------------------------------------##
	# These methods are based off of Redmine's timelog. They have been
	# modified to accommodate the needs of the Schedules plugin. In the
	# event that changes are made to the original, these methods will need
	# to be updated accordingly. As such, efforts should be made to modify
	# these methods as little as possible as they're effectively a branch
	# that we want to keep in sync.

  def report
    @available_criterias = { 'project' => {:sql => "IFNULL(#{ScheduleEntry.table_name}.project_id, #{TimeEntry.table_name}.project_id)",
                                          :klass => Project,
                                          :label => :label_project},
                             'member' => {:sql => "IFNULL(#{ScheduleEntry.table_name}.user_id, #{TimeEntry.table_name}.user_id)",
                                         :klass => User,
                                         :label => :label_member}
                           }
    
    @criterias = params[:criterias] || []
    @criterias = @criterias.select{|criteria| @available_criterias.has_key? criteria}
    @criterias.uniq!
    @criterias = @criterias[0,3]
    
    @columns = (params[:columns] && %w(year month week day).include?(params[:columns])) ? params[:columns] : 'month'
    
    retrieve_date_range
    
    unless @criterias.empty?
      sql_select = @criterias.collect{|criteria| @available_criterias[criteria][:sql] + " AS " + criteria}.join(', ')
      sql_group_by = @criterias.collect{|criteria| @available_criterias[criteria][:sql]}.join(', ')
      
      sql = "SELECT #{sql_select}, IFNULL(YEAR(date),tyear) as tyear, IFNULL(MONTH(date), tmonth) as tmonth, IFNULL(WEEK(date, 1), tweek) as tweek, IFNULL(date, spent_on) as date, SUM(#{ScheduleEntry.table_name}.hours) AS hours, SUM(#{TimeEntry.table_name}.hours) AS logged_hours"
      sql << " FROM #{ScheduleEntry.table_name}"
      sql << " LEFT JOIN #{TimeEntry.table_name} ON #{ScheduleEntry.table_name}.project_id = #{TimeEntry.table_name}.project_id"
      sql << "   AND #{ScheduleEntry.table_name}.user_id = #{TimeEntry.table_name}.user_id"
      sql << "   AND #{ScheduleEntry.table_name}.date = #{TimeEntry.table_name}.spent_on"
      sql << " LEFT JOIN #{Project.table_name} ON #{ScheduleEntry.table_name}.project_id = #{Project.table_name}.id"
      sql << " WHERE"
      sql << " (%s) AND" % @project.project_condition(Setting.display_subprojects_issues?) if @project
      sql << " (%s) AND" % Project.allowed_to_condition(User.current, :view_schedules)
      sql << " (date BETWEEN '%s' AND '%s')" % [ActiveRecord::Base.connection.quoted_date(@from.to_time), ActiveRecord::Base.connection.quoted_date(@to.to_time)]
      sql << " GROUP BY #{sql_group_by}, tyear, tmonth, tweek, date"
      sql << " UNION "
      sql << "SELECT #{sql_select}, IFNULL(YEAR(date),tyear) as tyear, IFNULL(MONTH(date), tmonth) as tmonth, IFNULL(WEEK(date, 1), tweek) as tweek, IFNULL(date, spent_on) as date, SUM(#{ScheduleEntry.table_name}.hours) AS hours, SUM(#{TimeEntry.table_name}.hours) AS logged_hours"
      sql << " FROM #{ScheduleEntry.table_name}"
      sql << " RIGHT JOIN #{TimeEntry.table_name} ON #{ScheduleEntry.table_name}.project_id = #{TimeEntry.table_name}.project_id"
      sql << "   AND #{ScheduleEntry.table_name}.user_id = #{TimeEntry.table_name}.user_id"
      sql << "   AND #{ScheduleEntry.table_name}.date = #{TimeEntry.table_name}.spent_on"
      sql << " LEFT JOIN #{Project.table_name} ON #{TimeEntry.table_name}.project_id = #{Project.table_name}.id"
      sql << " WHERE"
      sql << " date IS NULL AND"
      sql << " (%s) AND" % @project.project_condition(Setting.display_subprojects_issues?) if @project
      sql << " (%s) AND" % Project.allowed_to_condition(User.current, :view_schedules)
      sql << " (spent_on BETWEEN '%s' AND '%s')" % [ActiveRecord::Base.connection.quoted_date(@from.to_time), ActiveRecord::Base.connection.quoted_date(@to.to_time)]
      sql << " GROUP BY #{sql_group_by}, tyear, tmonth, tweek, spent_on"
      
      @hours = ActiveRecord::Base.connection.select_all(sql)
      
      @hours.each do |row|
        case @columns
        when 'year'
          row['year'] = row['tyear']
        when 'month'
          row['month'] = "#{row['tyear']}-#{row['tmonth']}"
        when 'week'
          row['week'] = "#{row['tyear']}-#{row['tweek']}"
        when 'day'
          row['day'] = "#{row['date']}"
        end
      end
      
      @total_hours = @hours.inject(0) {|s,k| s = s + k['hours'].to_f}
      
      @periods = []
      # Date#at_beginning_of_ not supported in Rails 1.2.x
      date_from = @from.to_time
      # 100 columns max
      while date_from <= @to.to_time && @periods.length < 100
        case @columns
        when 'year'
          @periods << "#{date_from.year}"
          date_from = (date_from + 1.year).at_beginning_of_year
        when 'month'
          @periods << "#{date_from.year}-#{date_from.month}"
          date_from = (date_from + 1.month).at_beginning_of_month
        when 'week'
          @periods << "#{date_from.year}-#{date_from.to_date.cweek}"
          date_from = (date_from + 7.day).at_beginning_of_week
        when 'day'
          @periods << "#{date_from.to_date}"
          date_from = date_from + 1.day
        end
      end
    end
    
    respond_to do |format|
      format.html { render :layout => !request.xhr? }
      format.csv  { send_data(report_to_csv(@criterias, @periods, @hours).read, :type => 'text/csv; header=present', :filename => 'timelog.csv') }
    end
  end
  
  def details
    sort_init 'date', 'desc'
    sort_update 'date' => 'date',
                'user' => 'user_id',
                'project' => "#{Project.table_name}.name",
                'hours' => 'hours'
    
    cond = ARCondition.new
    if @project.nil?
      cond << Project.allowed_to_condition(User.current, :view_schedules)
    end
    
    retrieve_date_range
    cond << ['date BETWEEN ? AND ?', @from, @to]

    ScheduleEntry.visible_by(User.current) do
      respond_to do |format|
        format.html {
          # Paginate results
          @entry_count = ScheduleEntry.count(:include => :project, :conditions => cond.conditions)
          @entry_pages = Paginator.new self, @entry_count, per_page_option, params['page']
          @entries = ScheduleEntry.find(:all, 
                                    :include => [:project, :user],
                                    :conditions => cond.conditions,
                                    :order => sort_clause,
                                    :limit  =>  @entry_pages.items_per_page,
                                    :offset =>  @entry_pages.current.offset)
          @total_hours = ScheduleEntry.sum(:hours, :include => :project, :conditions => cond.conditions).to_f

          render :layout => !request.xhr?
        }
        format.atom {
          entries = ScheduleEntry.find(:all,
                                   :include => [:project, :user],
                                   :conditions => cond.conditions,
                                   :order => "#{ScheduleEntry.table_name}.created_on DESC",
                                   :limit => Setting.feeds_limit.to_i)
          render_feed(entries, :title => l(:label_spent_time))
        }
        format.csv {
          # Export all entries
          @entries = ScheduleEntry.find(:all, 
                                    :include => [:project, :user],
                                    :conditions => cond.conditions,
                                    :order => sort_clause)
          send_data(entries_to_csv(@entries).read, :type => 'text/csv; header=present', :filename => 'timelog.csv')
        }
      end
    end
  end
##----------------------------------------------------------------------------##
	
	############################################################################
	# Private methods
	############################################################################
	private
	
	
	# Given a specific date, show the projects and users that the current user is
	# allowed to see and provide edit access to those permission is granted to.
	def save_entries
		if request.post? && params[:commit]
			save_scheduled_entries
			save_closed_entries unless params[:schedule_closed_entry].nil?
			
			# If all entries saved without issue, view the results
			if flash[:warning].nil?
				flash[:notice] = l(:label_schedules_updated)
				redirect_to({:action => 'index', :date => Date.parse(params[:date])})
			else
				redirect_to({:action => 'edit', :date => Date.parse(params[:date])})
			end
		end
	end
	
	
	#
	def save_scheduled_entries
	
		# Get the users and projects involved in this save 
		user_ids = params[:schedule_entry].collect { |user_id, projects_dates| user_id }
		users = User.find(:all, :conditions => "id IN ("+user_ids.join(',')+")").index_by { |user| user.id }
		project_ids = params[:schedule_entry].collect { |user_id, projects_dates| projects_dates.keys }.flatten
		projects = Project.find(:all, :conditions => "id IN ("+project_ids.join(',')+")").index_by { |project| project.id }
		defaults = get_defaults(user_ids).index_by { |default| default.user_id }
		
		# Save the user/project/day/hours quadrupelt assuming sufficient access
		params[:schedule_entry].each do |user_id, project_ids|
			user = users[user_id.to_i]
			default = defaults[user.id]
			project_ids.each do |project_id, dates|
				project = projects[project_id.to_i]
				if User.current.allowed_to?(:edit_all_schedules, project) || (User.current == user && User.current.allowed_to?(:edit_own_schedules, project)) || User.current.admin?
					dates.each do |date, hours|
					
						# Parse the given parameters
						date = Date.parse(date)
						hours = hours.to_f

						# Find the old schedule entry and create a new one
						old_entry = ScheduleEntry.find(:first, :conditions => {:project_id => project_id, :user_id => user_id, :date => date})
						new_entry = ScheduleEntry.new
						new_entry.project_id = project.id
						new_entry.user_id = user.id
						new_entry.date = date
						new_entry.hours = hours
						
						# If we're increasing the scheduled hours, confirm there's room
						defaults[user.id] = ScheduleDefault.new if defaults[user.id].nil?
						available_hours = defaults[user.id].weekday_hours[date.wday]
						
						if (new_entry.hours > 0) && (old_entry.nil? || old_entry.hours < hours) && (user != User.current) # && (!User.current.admin)
						 	available_hours -= new_entry.hours
						
							restrictions = "date = '#{date}' AND user_id = #{user.id}"
							available_hours -= ScheduleEntry.sum(:hours, :conditions => restrictions + " AND id <> #{old_entry.id}") if available_hours >= 0
							
							closed_entry = ScheduleClosedEntry.find(:first, :conditions => restrictions) if available_hours >= 0
							closed_hours = closed_entry.nil? ? 0 : closed_entry.hours 
							available_hours -= closed_hours
						end
						if available_hours >= 0
							save_entry(new_entry, old_entry)
						else
							flash[:warning] = "Some user's entries could not be saved as there was not enough room in their schedules."
						end 
					end
				end
			end
		end
	end
	
	
	#
	def save_entry(new_entry, old_entry)
		# Send mail if editing another user
		if (User.current != new_entry.user) && (params[:notify]) && (old_entry.nil? || new_entry.hours != old_entry.hours) && (new_entry.user.allowed_to?(:view_schedules, project))
			ScheduleMailer.deliver_future_changed(User.current, new_entry.user, new_entry.project, new_entry.date, new_entry.hours) 
		end
		
		# Save the changes
		new_entry.save if new_entry.hours > 0
		old_entry.destroy unless old_entry.nil?
	end
	
	
	def save_closed_entries

		# Get the users and projects involved in this save 
		user_ids = params[:schedule_closed_entry].collect { |user_id, dates| user_id }
		users = User.find(:all, :conditions => "id IN ("+user_ids.join(',')+")").index_by { |user| user.id }
	
		# Save the user/day/hours triplet assuming sufficient access
		params[:schedule_closed_entry].each do |user_id, dates|
			user = users[user_id.to_i]
			if (User.current == user) || User.current.admin?
				dates.each do |date, hours|
					old_entry = ScheduleClosedEntry.find(:first, :conditions => {:user_id => user_id, :date => date})
					new_entry = ScheduleClosedEntry.new
					new_entry.user_id = user.id
					new_entry.date = date
					new_entry.hours = hours.to_f
					new_entry.save if new_entry.hours > 0
					old_entry.destroy unless old_entry.nil?
				end
			end
		end
	end

	# Save the given default availability if one was provided	
	def save_default
		if request.post? && params[:commit]
		
			@user = User.current
		
			# Determine the user's current availability default
			@schedule_default = ScheduleDefault.find_by_user_id(@user.id)
			@schedule_default ||= ScheduleDefault.new 
			@schedule_default.weekday_hours ||= [0,0,0,0,0,0,0] 
			@schedule_default.user_id = @user.id
			
			# Save the new default
			@schedule_default.weekday_hours = params[:schedule_default].sort.collect { |a,b| [b.to_f, 0.0].max }
			@schedule_default.save
			
			# Inform the user that the update was successful 
			flash[:notice] = l(:notice_successful_update)
			redirect_to({:action => 'my'})
		end
	end
	
	
	# Get schedule entries between two dates for the specified users and projects
	def get_entries(project_restriction = true)
		restrictions = "(date BETWEEN '#{@calendar.startdt}' AND '#{@calendar.enddt}')"
		restrictions << " AND user_id = " + @user.id.to_s unless @user.nil?
		if project_restriction
			restrictions << " AND project_id IN ("+@projects.collect {|project| project.id.to_s }.join(',')+")"
			restrictions << " AND project_id = " + @project.id.to_s unless @project.nil?
		end
		ScheduleEntry.find(:all, :conditions => restrictions)
	end
	
	
	# Get closed entries between two dates for the specified users
	def get_closed_entries
		restrictions = "(date BETWEEN '#{@calendar.startdt}' AND '#{@calendar.enddt}')"
		restrictions << " AND user_id IN ("+@users.collect {|user| user.id.to_s }.join(',')+")"
		ScheduleClosedEntry.find(:all, :conditions => restrictions)
	end
	
	
	# Get schedule defaults for the specified users
	def get_defaults(user_ids = nil)
		restrictions = "user_id IN ("+@users.collect {|user| user.id.to_s }.join(',')+")" unless @users.nil?
		restrictions = "user_id IN ("+user_ids.join(',')+")" unless user_ids.nil?
		ScheduleDefault.find(:all, :conditions => restrictions)
	end
	
	
	# Get availability entries between two dates for the specified users
	def get_availabilities

		# Get the user's scheduled entries
		entries_by_user = get_entries(false).group_by{ |entry| entry.user_id }
		entries_by_user.each { |user_id, user_entries| entries_by_user[user_id] = user_entries.group_by { |entry| entry.date } }

		# Get the user's scheduled unavailabilities
		closed_entries_by_user = get_closed_entries.group_by { |closed_entry| closed_entry.user_id }
		closed_entries_by_user.each { |user_id, user_entries| closed_entries_by_user[user_id] = user_entries.index_by { |entry| entry.date } }

		# Get the user's default availability
		defaults_by_user = get_defaults.index_by { |default| default.user.id }

		# Generate and return the availabilities based on the above variables 
		availabilities = Hash.new
		(@calendar.startdt..@calendar.enddt).each do |day|
			availabilities[day] = Hash.new
			@users.each do |user|
				availabilities[day][user.id] = 0
				availabilities[day][user.id] = defaults_by_user[user.id].weekday_hours[day.wday] unless defaults_by_user[user.id].nil?
				availabilities[day][user.id] -= entries_by_user[user.id][day].collect {|entry| entry.hours }.sum unless entries_by_user[user.id].nil? || entries_by_user[user.id][day].nil?
				availabilities[day][user.id] -= closed_entries_by_user[user.id][day].hours unless closed_entries_by_user[user.id].nil? || closed_entries_by_user[user.id][day].nil?
				availabilities[day][user.id] = [0, availabilities[day][user.id]].max
			end
		end
		availabilities
	end
	
	
	# Find the project associated with the given version
	def find_project
		@version = Version.find(params[:id])
		@project = @version.project
		deny_access unless User.current.allowed_to?(:edit_all_schedules, @project) && User.current.allowed_to?(:manage_versions, @project)
	rescue ActiveRecord::RecordNotFound
		render_404
	end
	
	
	# Determines if a given relation will prevent another from being worked on
	def schedule_relation?(relation)
		return (relation.relation_type == "blocks" || relation.relation_type == "precedes")
	end
	
	
	# This function will schedule an issue for the earliest open schedule for the
	# issue's assignee. 
	def schedule_issue(issue)

		# Issues start no earlier than today
		possible_start = [Date.today]
		
		# Find out when parent issues from this version have been tentatively scheduled for
		possible_start << issue.relations.collect do |relation|
			@open_issues[relation.issue_from_id] if (relation.issue_to_id == issue.id) && schedule_relation?(relation)
		end.compact.collect do |related_issue|
			related_issue if related_issue.fixed_version == issue.fixed_version
		end.compact.collect do |related_issue|
			related_issue.due_date
		end.max
		
		# Find out when parent issues outside of this version are due 
		possible_start << issue.relations.collect do |relation|
			Issue.find(relation.issue_from_id) if (relation.issue_to_id == issue.id) && schedule_relation?(relation)
		end.compact.collect do |related_issue|
			related_issue if related_issue.fixed_version != issue.fixed_version
		end.compact.collect do |related_issue|
			related_issue.due_date unless related_issue.due_date.nil?
		end.compact.max

		# Determine the earliest possible start date for this issue
		possible_start = possible_start.compact.max
		if issue.done_ratio == 100 || @entries[issue.assigned_to.id].nil?
			considered_date = possible_start + 1
		else 
			considered_date = @entries[issue.assigned_to.id].collect { |date, entry| entry if entry.date > possible_start }.compact.min { |a,b| a.date <=> b.date }.date
		end
		hours_remaining = issue.estimated_hours * ((100-issue.done_ratio)*0.01) unless issue.estimated_hours.nil?
		hours_remaining ||= 0
		
		# Chew up the necessary time starting from the earliest schedule opening
		# after the possible start dates.
		issue.start_date = considered_date
		while hours_remaining > 0
			while !@entries[issue.assigned_to.id].nil? && @entries[issue.assigned_to.id][considered_date].nil? && !@entries[issue.assigned_to.id].empty? && (considered_date < Date.today + 365) 
				considered_date += 1
			end
			raise l(:error_schedules_estimate_insufficient_scheduling, :user => issue.assigned_to, :issue => issue) if @entries[issue.assigned_to.id][considered_date].nil?
			if hours_remaining > @entries[issue.assigned_to.id][considered_date].hours
				hours_remaining -= @entries[issue.assigned_to.id][considered_date].hours
				@entries[issue.assigned_to.id][considered_date].hours = 0
			else
				@entries[issue.assigned_to.id][considered_date].hours -= hours_remaining
				hours_remaining = 0
			end
			@entries[issue.assigned_to.id].delete(considered_date) if @entries[issue.assigned_to.id][considered_date].hours == 0
		end
		issue.due_date = considered_date
		
		# Store the modified issue back to the global
		@open_issues[issue.id] = issue
	end

##----------------------------------------------------------------------------##
	# These methods are based off of Redmine's timelog. They have been
	# modified to accommodate the needs of the Schedules plugin. In the
	# event that changes are made to the original, these methods will need
	# to be updated accordingly. As such, efforts should be made to modify
	# these methods as little as possible as they're effectively a branch
	# that we want to keep in sync.

	  # Retrieves the date range based on predefined ranges or specific from/to param dates
  def retrieve_date_range
    @free_period = false
    @from, @to = nil, nil

    if params[:period_type] == '1' || (params[:period_type].nil? && !params[:period].nil?)
      case params[:period].to_s
      when 'today'
        @from = @to = Date.today
      when 'yesterday'
        @from = @to = Date.today - 1
      when 'current_week'
        @from = Date.today - (Date.today.cwday - 1)%7
        @to = @from + 6
      when 'last_week'
        @from = Date.today - 7 - (Date.today.cwday - 1)%7
        @to = @from + 6
      when '7_days'
        @from = Date.today - 7
        @to = Date.today
      when 'current_month'
        @from = Date.civil(Date.today.year, Date.today.month, 1)
        @to = (@from >> 1) - 1
      when 'last_month'
        @from = Date.civil(Date.today.year, Date.today.month, 1) << 1
        @to = (@from >> 1) - 1
      when '30_days'
        @from = Date.today - 30
        @to = Date.today
      when 'current_year'
        @from = Date.civil(Date.today.year, 1, 1)
        @to = Date.civil(Date.today.year, 12, 31)
      end
    elsif params[:period_type] == '2' || (params[:period_type].nil? && (!params[:from].nil? || !params[:to].nil?))
      begin; @from = params[:from].to_s.to_date unless params[:from].blank?; rescue; end
      begin; @to = params[:to].to_s.to_date unless params[:to].blank?; rescue; end
      @free_period = true
    else
      # default
    end
    
    @from, @to = @to, @from if @from && @to && @from > @to
    
    schedule_entry_minimum = ScheduleEntry.minimum(:date, :include => :project, :conditions => Project.allowed_to_condition(User.current, :view_schedules))
    schedule_entry_maximum = ScheduleEntry.maximum(:date, :include => :project, :conditions => Project.allowed_to_condition(User.current, :view_schedules))
    time_entry_minimum = TimeEntry.minimum(:spent_on, :include => :project, :conditions => Project.allowed_to_condition(User.current, :view_time_entries))
    time_entry_maximum = TimeEntry.maximum(:spent_on, :include => :project, :conditions => Project.allowed_to_condition(User.current, :view_time_entries))
    minimums = [Date.today, schedule_entry_minimum, time_entry_minimum].compact.sort;
    maximums = [Date.today, schedule_entry_maximum, time_entry_maximum].compact.sort;
    @from ||= minimums.first - 1
    @to   ||= maximums.last
  end
  
	  
  def find_optional_project
    if !params[:project_id].blank?
      @project = Project.find(params[:project_id])
    end
    deny_access unless User.current.allowed_to?(:view_schedules, @project, :global => true)
  end
##----------------------------------------------------------------------------##
	
	############################################################################
	# Instance method interfaces to class methods
	############################################################################
	def visible_projects
		self.class.visible_projects
	end
	def visible_users(members)		
		self.class.visible_users(members)
	end
end