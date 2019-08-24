# frozen_string_literal: true

class Api::GdriveController < ApplicationController
  protect_from_forgery except: %i[verify]

  def verify
    res, data = GdriveVerifyJob.register(
      params[:src_folder_url].to_s,
      params[:dst_folder_url].to_s
    )
    if res
      render json: {
        success: true,
        status: GdriveVerifyJob.get_job_state(data)
      }
    else
      render json: {
        success: false,
        message: data
      }
    end
  end

  def verify_status
    render json: GdriveVerifyJob.get_job_state(params[:id])
  end
end
