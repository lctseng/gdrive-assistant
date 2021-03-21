class Object
  def reload_lib!
    Dir["#{Rails.root}/lib/**/*.rb"].map { |f| [f, load(f)] }.all? { |a| a[1] }
  end
end
