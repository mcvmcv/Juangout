# The user model gets the admin pages Juango's own User has (password hashing, search and
# filters); these options add our fields to the list.
Admin.register_user_model!(Member;
    list_display = [:username, :display_name, :email, :is_staff, :date_joined])
