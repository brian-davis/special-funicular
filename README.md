Setup:

```bash
$ rails new friendly_id_debug
$ cd friendly_id_debug
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

Finish:

```bash
$ rails db:migrate db:seed
$ rails s
```

test form validations as normal.

add `friendly_id`:

```bash
$ bundle add friendly_id
$ rails g migration AddSlugToPosts slug:uniq
$ rails generate friendly_id
$ rails db:migrate
```

in `app/models/post.rb`:

```ruby
class Post < ApplicationRecord
  extend FriendlyId
  friendly_id :title, use: :slugged

  validates :title, presence: true
  validates :body, presence: true
end
```

And `app/controllers/posts_controller.rb`:

```ruby
def set_post
  @post = Post.friendly.find(params[:id])
end
```

Update existing records:

```ruby
>> Post.find_each(&:save)
```

Add update slug on title change:


In `app/models/post.rb`:

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

Go back to edit, and try submitting with a blank field.

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

Submitting error:

```
ActiveRecord::RecordNotFound (can't find record with friendly id: "88c1529f-c6d9-4a4a-8b27-45f259091baa")
```

unit tests:

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

This should be green already.  Add a red test:

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
    original_slug = post.slug.dup

    # execute
    post.assign_attributes({ title: "" }) # set .changes
    refute(post.valid?) # set .errors; falsy expected; trigger bug

    # desired behavior, slug not touched on failed validation for :title
    assert_nil(post.changes["slug"])
    assert_equal(original_slug, post.slug)
  end
```
debugging:

```ruby
> friendly_id_config.query_field
=> "slug"
> friendly_id_config.base
=> :title
> errors.map(&:attribute)
=> [:title]
```

The fix. in `app/models/post.rb`, add:

```ruby
  private def unset_slug_if_invalid
    if (
      errors.key?(friendly_id_config.base) ||
      errors.key?(friendly_id_config.slug_column.to_s)
    ) && attribute_changed?(friendly_id_config.slug_column.to_s)

      original_slug = changes[friendly_id_config.slug_column.to_s]&.first
      send "#{friendly_id_config.slug_column}=", original_slug
    end
  end
```

The `base` field (i.e. `:title`)should also be checked for errors.

with refactoring:

```ruby
class Post < ApplicationRecord
  extend FriendlyId
  friendly_id :title

  validates :title, presence: true
  validates :body, presence: true
end
```

config in initializer:

```ruby
  config.use :slugged
  config.use Module.new {
    def should_generate_new_friendly_id?
      slug.blank? || attribute_changed?(friendly_id_config.base.to_s)
    end

    private def unset_slug_if_invalid
      if (
        errors.key?(friendly_id_config.base) ||
        errors.key?(friendly_id_config.slug_column)
      ) && attribute_changed?(friendly_id_config.slug_column)

        original_slug = changes[friendly_id_config.slug_column]&.first
        send "#{friendly_id_config.slug_column}=", original_slug
      end
    end
  }
```
