module Sites
  class GoalsController < ApplicationController
    before_action :set_site
    before_action :set_goal, only: %i[edit update destroy]

    def index
      @goals = policy_scope(Goal).where(site: @site).order(:name)
      @period = Analytics::Period.parse(params[:period], site: @site)
      @report = Analytics::GoalReport.call(site: @site, period: @period).value!
    end

    def new
      @goal = @site.goals.new(match_type: "exact", kind: "pageview")
      authorize @goal
    end

    def create
      @goal = @site.goals.new(goal_params)
      authorize @goal

      if @goal.save
        redirect_to site_goals_path(@site), notice: "Goal created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize @goal
    end

    def update
      authorize @goal

      if @goal.update(goal_params)
        redirect_to site_goals_path(@site), notice: "Goal updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      authorize @goal
      @goal.destroy!
      redirect_to site_goals_path(@site), notice: "Goal deleted."
    end

    private

    def set_site
      @site = policy_scope(Site).find_by!(public_token: params[:site_public_token])
    end

    def set_goal
      @goal = @site.goals.find_by_public_id!(params[:id])
    end

    def goal_params
      params.expect(goal: %i[name kind match_value match_type default_value_cents currency])
    end
  end
end
