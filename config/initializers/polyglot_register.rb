# One-shot register with the Elixir site. Skip in tests so handler specs
# do not POST on boot.
Rails.application.config.after_initialize do
  next if Rails.env.test?

  Catalog.register_with_elixir
end
