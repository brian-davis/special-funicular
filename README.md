Debugging An Edge-Case Bug in The friendly_id Ruby Gem

[friendly_id](https://github.com/norman/friendly_id) is a very useful Ruby gem which is the de-facto standard for using slugged urls in Rails apps.  I was surprised to find some buggy behavior when using this in a new Rails 7 app (this very blog).  In this article I will document my debugging process and explain how I was able to identify and solve the problem code.  As a caveat, I will say I have not reviewed the gem's codebase top-to-bottom, and I am still in the follow-up stage of going through the issue-handling process in the gem's documentation.  This is only what I did in the short-term to get my own app working.

### Set Up ###

We can build a minimal Rails demo app to reproduce the issue:

```bash
$ rails new friendly_id_debug
$ cd friendly_id_debug
```

The [internal docs](https://github.com/norman/friendly_id/blob/master/lib/friendly_id/slug.rb) suggest a Post model, with this setup:

```ruby
#     class Post < ActiveRecord::Base
#       extend FriendlyId
#       friendly_id :title, :use => :slugged
#     end
```

This is the exact use case.  Let's build it:

```bash
$ rails g scaffold Post title:string body:text
$ rails db:migrate
```

In `app/models/post.rb`:

```ruby
class Post < ApplicationRecord
  validates :title, presence: true
  validates :body, presence: true
end
```

In `db/seeds.rb`

```ruby
10.times do |i|
  Post.create({
    title: "Post #{i + 1}",
    body: "words" * 100
  })
end
```

Finally:

```
$ rails db:migrate db:seed
$ rails s
```

The scaffolded app should be up and running.  Navigate in the browser to: `http://localhost:3000/posts` which is the `Post` index page. Click first 'show' link, and you should now be at: `http://localhost:3000/posts/1`.  This is standard behavior, as expected.  Click 'edit' to bring up a form at `http://localhost:3000/posts/1/edit`.  Try submitting form with either or both fields blank.  You should see the standard validation messages:

```html
2 errors prohibited this post from being saved:
Title can't be blank
Body can't be blank
```

Fill in values again, submit, and everything should update normally.

### Reproduce The Error ###

Now let's add `friendly_id`.  As per the Readme:

```bash
$ bundle add friendly_id
$ rails g migration AddSlugToPosts slug:uniq
$ rails generate friendly_id
$ rails db:migrate
```

Update the `Post` model in `app/models/post.rb`

```ruby
class Post < ApplicationRecord
  extend FriendlyId
  friendly_id :title, use: :slugged

  validates :title, presence: true
  validates :body, presence: true
end
```

And `PostsController` in `app/controllers/posts_controller.rb`:

```ruby
def set_post
  @post = Post.friendly.find(params[:id])
end
```

In a `rails c` console, update existing records:

```ruby
>> Post.find_each(&:save)
```

Now test with the UX, as before.  Start a server with `$ rails s` and navigate to `http://localhost:3000/posts`.  Click a 'show' link, and obverve the new URL, e.g. `http://localhost:3000/posts/post-2`.  As expected, URL is now a slug not an id. Click 'edit'.
In the form, change the "title" field from "Post 2" to "AAAAA".  The update should work,
but the url is still `http://localhost:3000/posts/post-2`.  This is expected,
because changing the slug on title change is not default behavior, the [gem
documentation]((https://github.com/norman/friendly_id/blob/master/lib/friendly_id/slug.rb)) says so:

```ruby
#### Deciding When to Generate New Slugs
#
# As of FriendlyId 5.0, slugs are only generated when the `slug` field is nil. If
# you want a slug to be regenerated,set the slug field to nil:
#
#     restaurant.friendly_id # joes-diner
#     restaurant.name = "The Plaza Diner"
#     restaurant.save!
#     restaurant.friendly_id # joes-diner
#     restaurant.slug = nil
#     restaurant.save!
#     restaurant.friendly_id # the-plaza-diner
#
# You can also override the
# {FriendlyId::Slugged#should_generate_new_friendly_id?} method, which lets you
# control exactly when new friendly ids are set:
#
#     class Post < ActiveRecord::Base
#       extend FriendlyId
#       friendly_id :title, :use => :slugged
#
#       def should_generate_new_friendly_id?
#         title_changed?
#       end
#     end
#
# If you want to extend the default behavior but add your own conditions,
# don't forget to invoke `super` from your implementation:
#
#     class Category < ActiveRecord::Base
#       extend FriendlyId
#       friendly_id :name, :use => :slugged
#
#       def should_generate_new_friendly_id?
#         name_changed? || super
#       end
#     end
#
```

OK. Because I want this behavior, I will add an override method. In `app/models/post.rb`:

```ruby
class Post < ApplicationRecord
  extend FriendlyId
  friendly_id :title, use: :slugged

  validates :title, presence: true
  validates :body, presence: true

  def should_generate_new_friendly_id?
    title_changed?
  end
end
```

The docs are confusing as to when `super` is actually needed.  I have
reproduced the bug I am looking into here both ways, so it doesn't seem to matter in this case.

Testing again, editing the previous record, and changing "AAAAA" to "AAAAA2", everything is working OK, and new url is now `http://localhost:3000/posts/aaaaa2`.

Here is the bug.  Go back to edit, and try submitting with a blank field.  The validation messages are displayed correctly, as before.

```html
1 error prohibited this post from being saved:
Title can't be blank
```

But now open a chrome inpsector and look at the form:

```html
<form action="/posts/88c1529f-c6d9-4a4a-8b27-45f259091baa" ...>
  ...
</form>
```

The `action` value _should be_ `"/posts/aaaaa"`, i.e., the same as before.  There was a validation error on `title`, so we should reject any further changes or persistence.  But instead there is something bizarre.  Submitting _this_ form, even with a valid field, will fail because there will be no route that matches this.  Checking the server logs will reveal this error:

```
ActiveRecord::RecordNotFound (can't find record with friendly id: "88c1529f-c6d9-4a4a-8b27-45f259091baa")
```

which fails silently in the UX for form submissions.

### Isolating The Faulty Code ###

Something else is going on.  Let's write some unit tests.

In `test/models/post_test.rb` add:

```ruby
require "test_helper"

class PostTest < ActiveSupport::TestCase
  # normal use
  test "slug updates when title updates" do
    # set up
    post = Post.create({
      title: "My First Post",
      body: "My Deep Thoughts"
    })
    assert_equal("my-first-post", post.slug)

    # execute
    post.update(title: "Changed My Mind")

    # desired behavior
    assert_equal("changed-my-mind", post.slug)
  end
end
```

This should be green when running `$ rails test test/models/post_test.rb:5`.  Now to add a test which will be red:

```ruby
  # edge case
  # validatition bug:
  # Expected ["my-second-post", "2d883d62-9c3e-4158-9daf-b34e655dcc3e"] to be nil.
  # This bug will break form behavior after an invalid submission
  test "slug unchanged when title update is invalid, in :valid? call" do
    # set up
    post = Post.create({
      title: "My Second Post",
      body: "More Deep Thoughts"
    })
    original_title = post.title.dup
    original_slug = post.slug.dup

    # execute
    post.assign_attributes({ title: "" }) # set .changes
    refute(post.valid?) # set .errors; falsy expected; trigger bug

    # desired behavior
    assert_nil(post.changes["slug"])
  end
```

Some previous experimenting showed me that this was actually happening even when running `.valid?` against the model object, not necessarily on `save` or `update`, although it does of course happen there as well as those methods run validation callbacks.  The erroneous UUID-string is showing up in the `slug` value on the `post.changes` hash-like object.  We'll dig into this more in a little bit when proposing a solution, but first I will add another, similar test, which will also be red:

```ruby
# edge case
# validatition bug:
# Expected ["my-third-post", "2d883d62-9c3e-4158-9daf-b34e655dcc3e"] to be nil.
# This bug will break form behavior after an invalid submission
test "slug unchanged when title update is invalid, in :save call" do
  # set up
  post = Post.create({
    title: "My Third Post",
    body: "My Deepest Thoughts"
  })
  original_title = post.title.dup
  original_slug = post.slug.dup

  # execute
  post.update(title: "")

  # desired behavior
  assert_equal(post.errors["title"], ["can't be blank"])
  assert_equal(original_slug, post.slug)
end
```

This is the same test, but which is called on `.save` (which runs validation callbacks), reflecting the most likely real-world use case.  `$ rails test test/models/post_test.rb` will have two failing tests

To dig into the gem code:

```bash
$ code $(bundle info friendly_id --path)
```

Which will open up the gem as a project in VSCode.  Digging into the gem code, `in lib/friendly_id/slugged.rb`, you can see why this is happening at the validation stage:

```ruby
def self.included(model_class)
  # code ...
  model_class.before_validation :set_slug
  model_class.before_save :set_slug
  model_class.after_validation :unset_slug_if_invalid
end
```

I'm not sure why `:set_slug` runs on both `before_validation` _and_ on `before_save`, but the logic is that the erroneous UUID we're seeing is a temporary value, which should be canceled by `unset_slug_if_invalid` when validations fail.  It seems there is something amiss with this method, because this temporary value is apparently _not_ being unset as it should.

Here is how it looks:

```ruby
def unset_slug_if_invalid
  if errors.key?(friendly_id_config.query_field) && attribute_changed?(friendly_id_config.query_field.to_s)
    diff = changes[friendly_id_config.query_field]
    send "#{friendly_id_config.slug_column}=", diff.first
  end
end
private :unset_slug_if_invalid
```

I used a  strategically-placed `binding.pry` debugger to inspect the values for the various look-ups in this method, and some introspection methods I experimented with:

```ruby
> friendly_id_config.query_field
=> "slug"
> friendly_id_config.base
=> :title
> errors.map(&:attribute)
=> [:title]
```

It is the `:title` attribute on `Post` which is showing up in the `errors`, yet the logic depends on a change to the `:slug` field on the `friendly_id_slugs` table.  Why would that show up on the `errors` object on Post?  That seems to be the error, and should be changed to `friendly_id_config.base`, which is the model attribute which is failing the validation.

### The Fix ###

Some more digging shows that `query_field` is simply an alias for the `slug_column` method.  I'm not sure of the reasoning or history there, so I won't change that, but will just override the `:unset_slug_if_invalid` method on my own `Post` model.  Back in `app/models/post.rb`, add:

```ruby
  private def unset_slug_if_invalid
    if errors.key?(friendly_id_config.base) &&
      attribute_changed?(friendly_id_config.query_field.to_s)

      original_slug = changes[friendly_id_config.slug_column]&.first
      send "#{friendly_id_config.slug_column}=", original_slug
    end
  end
```

The tests in `$ rails test test/models/post_test.rb` should be all green.

### Refactoring ###

The immediate problem has been fixed, but I will do just a bit of refactoring.  This new logic is cluttering up my `Post` model, and ought to be moved into an initializer.  The gem setup process has already created one, at config/initializers/friendly_id.rb. In the initializer at line 78 there is this a documentation section for `### Controlling when slugs are generated`.  This describes the current use case.  the `use: :slugged` option can be set globally in the initializer, and override methods can be placed here.  Before doing that, I cut the unnecessary methods, and the option on `friendly_id :title`, from `Post`:

```ruby
class Post < ApplicationRecord
  extend FriendlyId
  friendly_id :title

  validates :title, presence: true
  validates :body, presence: true
end
```

Now I can uncomment the relevant section in the intializer, and paste the new methods in (with some changes):

```ruby
  config.use :slugged
  config.use Module.new {
    def should_generate_new_friendly_id?
      slug.blank? || attribute_changed?(friendly_id_config.base.to_s)
    end

    private def unset_slug_if_invalid
      if errors.key?(friendly_id_config.base) && # e.g. :test on Post
        attribute_changed?(friendly_id_config.slug_column.to_s) # i.e. :slug on :frienly_id_slugs

        original_slug = changes[friendly_id_config.slug_column.to_s]&.first
        send "#{friendly_id_config.slug_column}=", original_slug
      end
    end
  }
```

I have done some small refactors, using `slug.blank?` as suggested in _these_ comments (albeit with a syntax error), and am also using `friendly_id_config.base.to_s` in `should_generate_new_friendly_id?` to avoid hard-coding `:title`, which of course, could change if this module were used on another model class.   All tests still pass, and running through the UX again in the browser confirms that the temporary slug value never makes its way to the `form`.

This has been a walkthrough of my Ruby debugging process for a real-world issue I've encountered when building a Rails app.  It gets me to the point where I can proceed beyond the roadblock of a seeming bug in a required library, to continue coding on my app.  The next step in the process will be following up with [the library author's](https://github.com/norman/friendly_id) suggested issue-hanling process, which would be to fork the gem, debug and test directly on the gem locally, then make a pull request.
