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
    assert_equal("changed-my-mind", post.slug)
  end

  # edge case
  # validation gotcha:
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
    post.assign_attributes({ title: "" })
    refute(post.valid?)
    assert_nil(post.changes["slug"])
  end

  # edge case
  # validation gotcha:
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
    assert_equal(post.errors["title"], ["can't be blank"])
    assert_equal(original_slug, post.slug)
  end
end
